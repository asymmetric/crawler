require 'rubygems'
require 'bundler'
Bundler.require :default, ENV['APP_ENV'] || :development

class Crawler

  LOGS_DIR = "logs"

  def initialize url
    @redis = Redis.new
    @redis.flushdb
    @connection = Excon.new(
      url,
      persistent: true,
      middlewares: Excon.defaults[:middlewares] + [ Excon::Middleware::RedirectFollower ]
    )
    hostname = @connection.params[:hostname]
    @logger_ok = Logger.new("#{LOGS_DIR}/#{hostname}.ok.log")
    @logger_err = Logger.new("#{LOGS_DIR}/#{hostname}.error.log")
    @links = []
    @results = {}
    @total = 0
  end

  def go
    parse '/', true
    count = @redis.scard 'links'
    @total = count
    @logger_ok.info "Level 1: found #{count} links: parsing its"
    @redis.smembers('links').each do |link|
      @redis.srem 'links', link
      parse link, true
    end
    count = @redis.scard 'links'
    @total += count
    @logger_ok.info "Level 2: found #{count} links: parsing its"
    @redis.smembers('links').each do |link|
      @redis.srem 'links', link
      parse link, true
    end
    puts "crawled #{@total} links"
    @results.each do |url, code|
      @logger_ok.info "#{code} #{url}"
      puts url
    end
  end

  private
  def add_link path
    path.gsub!(Regexp.new("^#{@base_url}"), "")
    path.gsub('\"')
    unless path.match(/^$|^#|^http|^mailto|\/redirect\?goto/) || (@results[path] && @results[path] > 0)
      @redis.sadd 'links', path
    end
  end

  def parse path, get_links=false
    response = @connection.get(persistent: true)
    status_code = response.status
    @results[path] = status_code
    if get_links
      if status_code < 400
        @logger_ok.debug "#{status_code} : #{path}"
        doc = Nokogiri::HTML(response.body)
        doc.css('a').each do |node|
          # insert the link
          link = node['href']
          next unless link
          add_link link
        end
      else
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

Crawler.new("http://#{@domain}").go
