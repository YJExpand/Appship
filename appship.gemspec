Gem::Specification.new do |spec|
  spec.name          = "appship"
  spec.version       = "0.1.0"
  spec.authors       = ["YJExpand"]
  spec.email         = ["yjexpand@163.com"]
  spec.summary       = "A standalone iOS build, IPA packaging, badge and app distribution CLI"
  spec.description   = "Build any Xcode workspace or project, optionally add an app icon badge, package an IPA and upload it to supported app distribution platforms."
  spec.homepage      = "https://github.com/YJExpand/Appship"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["README.md", "LICENSE", "bin/**/*", "exe/**/*", "lib/**/*", "test/**/*", ".appship.yml.example"].select { |f| File.file?(f) }
  spec.bindir        = "exe"
  spec.executables   = ["appship"]
  spec.require_paths = ["lib"]
end
