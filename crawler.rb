require 'rubygems'
require 'bundler'
Bundler.require :default, ENV['APP_ENV'] || :development

$redis = Redis.new
$redis.flushdb

class Crawler
  include Celluloid
  include Celluloid::Logger
  include Celluloid::Notifications

  def initialize url
    @connection = Excon.new(
      url,
      persistent: true,
      middlewares: Excon.defaults[:middlewares] + [ Excon::Middleware::RedirectFollower ]
    )
  end

  def start
    loop do
      while (link = $redis.spop 'new-links') do
        info "Thread #{Thread.current.object_id} parsing #{link}"
        parse link, true
      end
      $redis.incr 'idle'
      publish 'going idle'
      $redis.brpop 'blocker'
    end
  end

  def root
    parse '/', true
    # count = $redis.scard 'new-links'
    # @total = count
    # info "Level 1: found #{count} links: parsing its"
    # count = $redis.scard 'new-links'
    # @total += count
    # info "Level 2: found #{count} links: parsing its"
    # info "crawled #{@total} total links"
  end

  private
  def add_link path
    path.gsub!(Regexp.new("^#{@base_url}"), "")
    path.gsub('\"')
    path.gsub!(/#(.*)$/, '')
    unless path.match(/^$|^#|^http|^mailto|\/redirect\?goto/)
      unless $redis.sismember 'visited-links', path
        idle = $redis.get('idle')
        $redis.multi do
          if $redis.sadd 'new-links', path
            $redis.sadd 'visited-links', path
            $redis.decr 'idle' unless (idle == 0 || idle.nil? )
            $redis.lpush 'blocker', true
          end
        end
      end
    end
  end

  def parse path, get_links=false
    response = @connection.get(path: path, persistent: true)
    status_code = response.status
    if get_links
      if status_code < 400
        $redis.hmset :success, path, status_code
        # debug "#{status_code} : #{path}"
        doc = Nokogiri::HTML(response.body)
        doc.css('a').each do |node|
          # insert the link
          link = node['href']
          next unless link
          add_link link
        end
      else
        $redis.hmset :error, path, status_code
        error "#{status_code}: #{path}"
      end
    end
  rescue URI::InvalidURIError
    error "Error parsing #{path}"
  rescue Excon::Errors::SocketError => e
    error e.message
    retry
  end
end

class Observer
  include Celluloid
  include Celluloid::Logger
  include Celluloid::Notifications

  def initialize
    subscribe 'going idle', :on_idle
  end

  def on_idle(topic)
    info "count: #{$redis.get('idle')}"
    if $redis.get('idle').to_i >= POOL_SIZE
      signal :all_idle
    end
  end

  def wait_all_idle
    wait(:all_idle)
    total = $redis.scard 'visited-links'
    errors = $redis.hkeys(:error).count
    oks = $redis.hkeys(:success).count
    info "crawled #{total} links, #{oks} OK, #{errors} errors"
    $redis.hgetall(:success).each do |path|
      info path
    end
    $redis.hgetall(:error).each do |path|
      error path
    end
    info "exiting"
  end
end

@domain = ARGV[0]

POOL_SIZE = 9

root = Crawler.new "http://#{@domain}"
root.root

pool = Crawler.pool(size: POOL_SIZE, args: "http://#{@domain}")
(1..POOL_SIZE).map { |x| pool.async.start }
observer = Observer.new
observer.wait_all_idle
