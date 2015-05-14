require "net/http"
require "uri"
require 'nokogiri'
require 'awesome_print'
require 'logger'

class Crawler

  LOGS_DIR = "logs"

  def initialize url
    @base_url = url
    uri = URI.parse(@base_url)
    @logger_ok = Logger.new("#{LOGS_DIR}/#{uri.host}.ok.log")
    @logger_err = Logger.new("#{LOGS_DIR}/#{uri.host}.error.log")
    @http = Net::HTTP.new(uri.host, uri.port)
    @links = []
    @results = {}
  end

  def add_link path
    path.gsub!(Regexp.new("^#{@base_url}"), "")
    path.gsub('\"')
    unless path.match(/^$|^#|^http|^mailto|\/redirect\?goto/) || (@results[path] && @results[path] > 0)      
      @links << path 
    end
  end

  def parse path, get_links=false
    uri = URI.parse(path)
    request = Net::HTTP::Get.new(path)
    response = @http.request(request)
    code = response.code.to_i
    @results[path] = code
    if get_links
      if code < 400
        @logger_ok.debug "#{code} : #{path}"
        doc = Nokogiri::HTML(response.body)
        doc.css('a').each do |node|
          # insert the link        
          link = node['href']
          next unless link
          add_link link             
        end
      else 
        @logger_err.error "#{code}: #{path}"
      end 
    end
  end  

  def go
    parse '/', true
    @links.uniq!
    @logger_ok.info "Level 1: found #{@links.count} links: parsing its"
    @links.each do |link|
      @links.delete(link)
      parse link, true
    end
    @links.uniq!
    @logger_ok.info "Level 2: found #{@links.count} links: parsing its"
    @links.each do |link|
      @links.delete(link)
      parse link
    end
    @results.each do |url, code|
      @logger_ok.info "#{code} #{url}"
      puts url
    end
  end

end

@domain = ARGV[0]

unless File.directory?(Crawler::LOGS_DIR)
  FileUtils.mkdir_p(Crawler::LOGS_DIR)
end

Crawler.new("http://#{@domain}").go
