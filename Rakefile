desc "Build the kimio binary"
task :build do
  sh "crystal build src/kimi.cr -o kimio --warnings none --no-color"
end

desc "Build and run the TUI"
task :run => :build do
  sh "./kimio --yolo"
end

desc "Run the test suite"
task :spec do
  sh "crystal spec --warnings none --no-color"
end

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    sh "KIMI_PROVIDER=mock ./kimio --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    sh "KIMI_PROVIDER=mock KIMI_MOCK_SCRIPT=thinking ./kimio --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    sh "KIMI_PROVIDER=mock KIMI_MOCK_SCRIPT=thinking-tools ./kimio --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    sh "KIMI_PROVIDER=mock KIMI_MOCK_SCRIPT=markdown ./kimio --tui-prompt 'mock' --yolo"
  end
end

desc "Remove build artifacts"
task :clean do
  rm_f "kimio"
end
