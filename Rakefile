require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'yard'

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = ["-c", "-f progress", "-r ./spec/helper.rb"]
  t.pattern = 'spec/**/*_spec.rb'
end
task :default => :spec
