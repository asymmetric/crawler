Crawler
=======

A multi-threaded web crawler that checks for the HTTP status of your links.

It queries every link on your site, and prints out the links which return an
error.

Usage
-----

After running `bundle install`:

* run redis with `bundle exec foreman` or `redis-server -c redis/redis.conf`
* run the crawler with `bundle exec ruby crawler.rb example.com`

Testing locally
---------------

If you want to run it against a local website, you can use Docker Compose to
fire up an instance of Wordpress, where you can easily add pages and test that
everything works smoothly.
