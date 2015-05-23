require 'rubygems'
require 'bundler'
Bundler.require :default, ENV['APP_ENV'] || :development

$redis = Redis.new
$redis.flushdb

class Crawler
  include Celluloid

  LOGS_DIR = "logs"

  def initialize url
    @connection = Excon.new(
      url,
      persistent: true,
      middlewares: Excon.defaults[:middlewares] + [ Excon::Middleware::RedirectFollower ]
    )
    @logger_ok = ::Logger.new("#{LOGS_DIR}/crawler.log")
    @logger_err = ::Logger.new("#{LOGS_DIR}/crawler.error.log")
    @links = []
  end

  def start
    loop do
      while (link = $redis.spop 'links') do
        # process message
        @logger_ok.info "parsing #{link}"
        parse link, true
      end
      $redis.brpop 'blocker'
    end
  end

  def root
    parse '/', true
    count = $redis.scard 'links'
    @total = count
    @logger_ok.info "Level 1: found #{count} links: parsing its"
    count = $redis.scard 'links'
    @total += count
    @logger_ok.info "Level 2: found #{count} links: parsing its"
    @logger_ok.info "crawled #{@total} total links"
    $redis.hgetall(:success).each do |path|
      @logger_ok.info path
    end
    $redis.hgetall(:error).each do |path|
      @logger_ok.error path
    end
  end

  private
  def add_link path
    path.gsub!(Regexp.new("^#{@base_url}"), "")
    path.gsub('\"')
    path.gsub!(/#(.*)$/, '')
    unless path.match(/^$|^#|^http|^mailto|\/redirect\?goto/)
      $redis.sadd 'links', path
    end
  end

  def parse path, get_links=false
    response = @connection.get(path: path, persistent: true)
    status_code = response.status
    if get_links
      if status_code < 400
        $redis.hmset :success, path, status_code
        # @logger_ok.debug "#{status_code} : #{path}"
        doc = Nokogiri::HTML(response.body)
        doc.css('a').each do |node|
          # insert the link
          link = node['href']
          next unless link
          if add_link link
            $redis.lpush 'blocker', true
          end
        end
      else
        $redis.hmset :error, path, status_code
        @logger_err.error "#{status_code}: #{path}"
      end
    end
    rescue URI::InvalidURIError
      @logger_err.error "Error parsing #{path}"
  end

end

@domain = ARGV[0]

unless File.directory?(Crawler::LOGS_DIR)
  FileUtils.mkdir_p(Crawler::LOGS_DIR)
end


#supervisor = Crawler.supervise "http://#{@domain}"
#root = supervisor.actors.first
root = Crawler.new "http://#{@domain}"
root.root

pool = Crawler.pool(args: "http://#{@domain}")
pool.start
