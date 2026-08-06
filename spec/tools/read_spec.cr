require "../spec_helper"

describe Hcode::Tools::Read do
  it "exposes JS-schema parameter names" do
    read = Hcode::Tools::Read.new("/tmp")
    params = read.parameters
    props = params["properties"].as_h
    props.has_key?("path").should be_true
    props.has_key?("line_offset").should be_true
    props.has_key?("n_lines").should be_true
    props.has_key?("filePath").should be_false
    props.has_key?("offset").should be_false
    props.has_key?("limit").should be_false
    required = params["required"].as_a.map(&.to_s)
    required.should contain("path")
  end

  it "reads a small file with N\\tcontent line format" do
    path = "/tmp/hcode-test-read-basic.txt"
    File.write(path, "alpha\nbeta\ngamma\n")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-basic.txt"})))
    result.is_error?.should be_false
    result.content.should contain("1\talpha")
    result.content.should contain("2\tbeta")
    result.content.should contain("3\tgamma")
    result.content.should contain("<system>")
    result.content.should contain("3 lines read from file starting from line 1.")
    result.content.should contain("Total lines in file: 3.")
  end

  it "still accepts legacy filePath/offset/limit args" do
    path = "/tmp/hcode-test-read-legacy.txt"
    File.write(path, "one\ntwo\nthree\nfour\n")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"filePath":"hcode-test-read-legacy.txt","offset":2,"limit":2})))
    result.is_error?.should be_false
    result.content.should contain("2\ttwo")
    result.content.should contain("3\tthree")
    result.content.should_not contain("1\tone")
    result.content.should_not contain("4\tfour")
  end

  it "errors when path is missing" do
    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("No path provided")
  end

  it "errors when file does not exist" do
    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-missing.txt"})))
    result.is_error?.should be_true
    result.content.should contain("does not exist")
  end

  it "errors when path is a directory" do
    dir = "/tmp/hcode-test-read-dir"
    Dir.mkdir_p(dir)

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-dir"})))
    result.is_error?.should be_true
    result.content.should contain("not a file")
  end

  it "blocks sensitive files via PathAccess (.env)" do
    path = "/tmp/hcode-test-read-env/.env"
    Dir.mkdir_p("/tmp/hcode-test-read-env")
    File.write(path, "SECRET=shhh\n")

    read = Hcode::Tools::Read.new("/tmp/hcode-test-read-env")
    result = read.execute(JSON.parse(%({"path":".env"})))
    result.is_error?.should be_true
    result.content.should contain("sensitive")
    result.content.should_not contain("shhh")
  end

  it "allows .env.example (sensitive-file exemption)" do
    path = "/tmp/hcode-test-read-envex/.env.example"
    Dir.mkdir_p("/tmp/hcode-test-read-envex")
    File.write(path, "SECRET=placeholder\n")

    read = Hcode::Tools::Read.new("/tmp/hcode-test-read-envex")
    result = read.execute(JSON.parse(%({"path":".env.example"})))
    result.is_error?.should be_false
    result.content.should contain("SECRET=placeholder")
  end

  it "rejects relative paths that escape the workspace" do
    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"../hcode-test-read-escape.txt"})))
    result.is_error?.should be_true
    result.content.should contain("not an absolute path")
  end

  it "rejects files containing NUL bytes" do
    path = "/tmp/hcode-test-read-nul.bin"
    File.write(path, String.build { |io| io << "foo\0bar" })

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-nul.bin"})))
    result.is_error?.should be_true
    result.content.should contain("not readable as UTF-8 text")
  end

  it "rejects non-UTF-8 bytes" do
    path = "/tmp/hcode-test-read-badutf8.bin"
    File.write(path, Bytes[0xff, 0xfe, 0x00])

    # Skip if File.write(String) coerced into something readable — write raw bytes.
    File.write(path, Bytes[0xff, 0xfe, 0xfd])
    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-badutf8.bin"})))
    result.is_error?.should be_true
    result.content.should contain("not readable as UTF-8 text")
  end

  it "respects line_offset and n_lines" do
    path = "/tmp/hcode-test-read-window.txt"
    File.write(path, (1..10).join('\n') + '\n')

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-window.txt","line_offset":4,"n_lines":3})))
    result.is_error?.should be_false
    result.content.should contain("4\t4")
    result.content.should contain("5\t5")
    result.content.should contain("6\t6")
    result.content.should_not contain("\t7\n")
    result.content.should contain("3 lines read from file starting from line 4.")
  end

  it "reads from the end of file with a negative line_offset" do
    path = "/tmp/hcode-test-read-tail.txt"
    File.write(path, (1..10).join('\n') + '\n')

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-tail.txt","line_offset":-3})))
    result.is_error?.should be_false
    result.content.should contain("8\t8")
    result.content.should contain("9\t9")
    result.content.should contain("10\t10")
    result.content.should contain("3 lines read from file starting from line 8.")
  end

  it "folds pure CRLF files to LF for display" do
    path = "/tmp/hcode-test-read-crlf.txt"
    File.write(path, "alpha\r\nbeta\r\n")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-crlf.txt"})))
    result.is_error?.should be_false
    result.content.should contain("1\talpha")
    result.content.should contain("2\tbeta")
    result.content.should_not contain("\r")
    result.content.should contain("Total lines in file: 2.")
  end

  it "renders mixed line endings with visible \\r" do
    path = "/tmp/hcode-test-read-mixed.txt"
    File.write(path, "alpha\r\nbeta\rgamma\n")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-mixed.txt"})))
    result.is_error?.should be_false
    # Lone CR inside "beta\rgamma" must be rendered as literal `\r`.
    result.content.should contain("\\r")
    result.content.should contain("carriage-return line endings are shown as")
  end

  it "truncates lines longer than MAX_LINE_LENGTH" do
    long = "x" * (Hcode::Tools::Read::MAX_LINE_LENGTH + 100)
    path = "/tmp/hcode-test-read-long.txt"
    File.write(path, long + '\n')

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-long.txt"})))
    result.is_error?.should be_false
    result.content.should contain("...")
    result.content.should contain("were truncated.")
  end

  it "stops at the MAX_BYTES budget" do
    read = Hcode::Tools::Read.new("/tmp")
    # Each rendered line ~ 200 bytes; 600 lines > 100KB.
    line = "y" * 199
    path = "/tmp/hcode-test-read-bytes.txt"
    File.write(path, (1..600).map { line }.join('\n') + '\n')

    result = read.execute(JSON.parse(%({"path":"hcode-test-read-bytes.txt"})))
    result.is_error?.should be_false
    result.content.should contain("Max #{Hcode::Tools::Read::MAX_BYTES} bytes reached.")
  end

  it "caps n_lines at MAX_LINES" do
    path = "/tmp/hcode-test-read-cap.txt"
    File.write(path, (1..3000).join('\n') + '\n')

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-cap.txt","n_lines":5000})))
    result.is_error?.should be_false
    result.content.should contain("Max #{Hcode::Tools::Read::MAX_LINES} lines reached.")
    result.content.should contain("Total lines in file: 3000.")
  end

  it "reports end of file when fewer lines are available" do
    path = "/tmp/hcode-test-read-eof.txt"
    File.write(path, "only\n")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-eof.txt","n_lines":50})))
    result.is_error?.should be_false
    result.content.should contain("End of file reached.")
  end

  it "treats an empty file as zero lines" do
    path = "/tmp/hcode-test-read-empty.txt"
    File.write(path, "")

    read = Hcode::Tools::Read.new("/tmp")
    result = read.execute(JSON.parse(%({"path":"hcode-test-read-empty.txt"})))
    result.is_error?.should be_false
    result.content.should contain("No lines read from file.")
    result.content.should contain("Total lines in file: 0.")
  end
end
