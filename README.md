# Faraday Dynamic Timeout Middleware

[![Continuous Integration](https://github.com/bdurand/faraday_dynamic_timeout/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/faraday_dynamic_timeout/actions/workflows/continuous_integration.yml)
[![Regression Test](https://github.com/bdurand/faraday_dynamic_timeout/actions/workflows/regression_test.yml/badge.svg)](https://github.com/bdurand/faraday_dynamic_timeout/actions/workflows/regression_test.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/faraday_dynamic_timeout.svg)](https://badge.fury.io/rb/faraday_dynamic_timeout)

This gem provides a Faraday middleware that allows you to set dynamic timeouts on HTTP requests based on the current number of requests being made to an endpoint. This is useful in that it allows you to set a long enough timeout to handle the worst case scenario when the system is healthy, but then set shorter timeouts as load increases so requests can fail fast in an unhealthy system.

The middleware requires a redis server to count the number of concurrent requests being made to an endpoint.

## Usage

The middleware can be installed in your Faraday connection like this:

```ruby
require "faraday_dynamic_timeout"

connection = Faraday.new do |faraday|
  faraday.request :dynamic_timeout, buckets: [
    {timeout: 8, max_requests: 5},
    {timeout: 1, max_requests: 10},
    {timeout: 0.5, max_requests: 20}
  ]
end
```

In this example, the timeout will be set to 8 seconds if there are 5 or fewer requests being made to the endpoint, 1 second if there are 10 or fewer requests, and 0.5 seconds if there are 20 or fewer requests. If there are more than 20 requests being made to the endpoint, an exception will be raised.

This kind of configuration allows you to set a long enough timeout to handle requests system is healthy, but then set shorter timeouts as load increases so requests can fail fast in an unhealthy system.

So, consider a web application that makes an HTTP request to a search service. Under normal load, the search service returns almost all results in under 200ms. However, there are some more complex queries that can take up to 5 seconds to complete. If we set the timeout to the search service at 5 seconds, it will be able to handle all queries, but if something happens to make that service unhealthy and all queries start taking 5 seconds, then the web application can end up in a situation where all of its threads are blocked waiting for the search service and the application becomes unresponsive. If we set the timeout to less than 5 seconds, then the complex queries will start timing out.

Using this middleware with a configuration like above can solve this problem. So if under normal load there are only ever 5 concurrent requests, we will be setting the timeout to 5 seconds. If the search service becomes unhealthy and queries start taking a little longer, then the timeout will be reduced to 1 second, and the web application will start timing out the complex queries. If the load keeps growing, the timeout will be reduced to 500ms. Finally, errors will start being raise without even making a requests once there are more than 20 concurrent requests. This will help you system fail fast so that it won't become unresponsive. User's will get errors when they try to search, but the rest of the functionality of the application will still be available. Additionally, this setup will limit the amount of load it is sending to the external search service which can give it a chance to recover.

TODO

### Configuration Options

TODO

- `:redis` - The redis connection to use. This should be a `Redis` object or a `Proc` that yields a `Redis` object. If not provided, it will default to the default connection returned by `Redis.new`. If you pass `nil`, the middleware will be disabled.

- `:name` - An optional name for the resource. By default the hostname and port of the request URL will be used to identify the resource. Each resource will report a separate count of concurrent requests and processes. If you want to group multiple resources together, you can provide a name here.

### Full Example

For this example, we will configure the `opensearch` gem with this middleware.

```ruby
# Set up a redis connection to coordinate counting concurrent requests.
redis = Redis.new(url: ENV.fetch("REDIS_URL"))

client = OpenSearch::Client.new(host: 'localhost', port: '9200') do |faraday|
  faraday.request :dynamic_timeout,
                  buckets: [
                    {timeout: 8, max_requests: 5},
                    {timeout: 1, max_requests: 10},
                    {timeout: 0.5, max_requests: 20}
                  ],
                  name: "opensearch",
                  redis: redis,
end
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem "faraday_dynamic_timeout"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install faraday_dynamic_timeout
```

## Contributing

Open a pull request on GitHub.

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
