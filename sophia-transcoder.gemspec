# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "sophia-transcoder/version"

Gem::Specification.new do |s|
  s.name        = "sophia-transcoder"
  s.version     = Sophia::Transcoder::VERSION
  s.authors     = ["Vitaly Tsevan"]
  s.email       = ["vitaly.tsevan@warecorp.com"]
  s.homepage    = ""
  s.summary     = "Sophia Transcoder"
  s.description = "Sophia Transcoder"

  s.rubyforge_project = "sophia-transcoder"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  # specify any dependencies here; for example:
  # s.add_development_dependency "rspec"
  # s.add_runtime_dependency "rest-client"
  s.add_runtime_dependency 'aws-sdk'
  s.add_runtime_dependency 'streamio-ffmpeg', '0.8.3'
  s.add_runtime_dependency(%q<activesupport>, [">= 3.1.0"])
  s.add_runtime_dependency 'i18n'

end
