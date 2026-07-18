desc "Build the hcode binary"
task :build do
  sh "crystal build src/hcode.cr -o hcode --warnings none --no-color"
end

desc "Build and run the TUI"
task :run => :build do
  sh "./hcode --yolo"
end

desc "Run the test suite"
task :spec do
  sh "crystal spec --warnings none --no-color"
end

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    sh "HCODE_PROVIDER=mock ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=thinking-tools ./hcode --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    sh "HCODE_PROVIDER=mock HCODE_MOCK_SCRIPT=markdown ./hcode --tui-prompt 'mock' --yolo"
  end
end

desc "Remove build artifacts"
task :clean do
  rm_f "hcode"
end
