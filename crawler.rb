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
        debug "Thread #{Thread.current.object_id} parsing #{link}"
        parse link, true
      end
      if $redis.brpop('blocker', 1).nil?
        Actor[:observer].async.job_done
        break
      end
    end
  end

  def root
    parse '/', true
  end

  private
  def add_link path
    path.gsub!(Regexp.new("^#{@base_url}"), "")
    path.gsub('\"')
    path.gsub!(/#(.*)$/, '')
    unless path.match(/^$|^#|^http|^mailto|\/redirect\?goto/)
      unless $redis.sismember 'visited-links', path
          if $redis.sadd 'new-links', path
            $redis.sadd 'visited-links', path
            $redis.lpush 'blocker', true
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
        doc = Oga.parse_html(response.body)
        doc.xpath('//a/@href').each do |a|
          # insert the link
          link = a.value
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
    @workers_left = POOL_SIZE
  end

  def job_done
    @workers_left -= 1

    if @workers_left == 0
      signal(:all_idle)
    end
  end

  def wait_all_idle
    wait(:all_idle)
    total = $redis.scard 'visited-links'
    errors = $redis.hkeys(:error).count
    oks = $redis.hkeys(:success).count
    info "crawled #{total} links, #{oks} OK, #{errors} errors"
    if errors > 0
      info "ERRORS:"
      info "------------------------"
      $redis.hgetall(:error).each do |entry|
        error "#{entry[0]}: #{entry[1]}"
      end
      info "------------------------"
    end
    debug "exiting"
  end
end

@domain = ARGV[0]

POOL_SIZE = 3

root = Crawler.new "http://#{@domain}"
root.root

pool = Crawler.pool(size: POOL_SIZE, args: "http://#{@domain}")

observer = Observer.new
Celluloid::Actor[:observer] = observer

(1..POOL_SIZE).map { |x| pool.async.start }

observer.wait_all_idle
