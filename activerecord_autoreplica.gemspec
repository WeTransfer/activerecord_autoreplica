Gem::Specification.new do |s|
  s.name = "activerecord_autoreplica"
  s.version = "2.0.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib"]
  s.authors = ["Julik Tarkhanov"]
  s.date = "2016-12-06"
  s.description = " Redirect all SELECT queries to a separate connection within a block "
  s.email = "me@julik.nl"
  s.extra_rdoc_files = [
    "LICENSE.txt",
    "README.md"
  ]
  s.homepage = "http://github.com/WeTransfer/activerecord_autoreplica"
  s.licenses = ["MIT"]
  s.rubygems_version = "2.4.5.1"
  s.summary = "Palatable-size read replica adapter for ActiveRecord"
  s.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  s.specification_version = 4
  s.add_runtime_dependency('activerecord', ["7.0.6"])
  s.add_development_dependency('rake', ["~> 12.3"])
  s.add_development_dependency('yard', [">= 0"])
  s.add_development_dependency('sqlite3', [">= 0"])
  s.add_development_dependency('rspec', ["~> 3.8"])
  s.add_development_dependency('rdoc', ["~> 6.1"])
  s.add_development_dependency('bundler', ["~> 1.0"])
end

