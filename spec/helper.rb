require 'rubygems'
require 'bundler'

Bundler.setup(:default, :development)

require 'active_record'
require 'activerecord_autoreplica'

RSpec.configure do |config|
  config.order = 'random'
  config.mock_with :rspec
end
