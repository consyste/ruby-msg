$:.unshift File.dirname(__FILE__) + '/lib'
require 'mapi/version'

PKG_NAME = 'ruby-msg-nx'
PKG_VERSION = Mapi::VERSION

Gem::Specification.new do |s|
	s.name = PKG_NAME
	s.version = PKG_VERSION
	s.licenses = ['MIT']
	s.summary = %q{Ruby Msg library.}
	s.description = %q{A library for reading and converting Outlook msg and pst files (mapi message stores).}
	s.authors = ['Charles Lowe', 'kenjiuno']
	s.email = %q{ku@digitaldolphins.jp}
	s.homepage = %q{https://github.com/HiraokaHyperTools/ruby-msg}

	s.executables = ['mapitool']
	s.files  = ['Home.md', 'COPYING', 'Rakefile', 'ChangeLog', 'ruby-msg.gemspec']
	s.files += Dir.glob('data/*.yaml')
	s.files += Dir.glob('lib/**/*.rb')
	s.files += Dir.glob('bin/*')

	s.add_runtime_dependency 'ruby-ole', '~> 1.2', '>=1.2.8'
	s.add_runtime_dependency 'vpim', '>= 0.360'
end

