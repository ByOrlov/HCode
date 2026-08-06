require "../spec_helper"
require "../../src/tools/read_media"

describe "Hcode::Tools.detect_media_file_type" do
  it "detects PNG" do
    header = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Image)
    detected.mime_type.should eq("image/png")
  end

  it "detects JPEG" do
    header = Bytes[0xFF, 0xD8, 0xFF, 0xE0]
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Image)
    detected.mime_type.should eq("image/jpeg")
  end

  it "detects GIF" do
    header = Bytes[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Image)
    detected.mime_type.should eq("image/gif")
  end

  it "detects MP4" do
    header = Bytes[0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Video)
    detected.mime_type.should eq("video/mp4")
  end

  it "detects text" do
    header = "hello world\n".to_slice
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Text)
  end

  it "detects unknown binary" do
    header = Bytes[0x00, 0x01, 0x02, 0x03]
    detected = Hcode::Tools.detect_media_file_type(header)
    detected.kind.should eq(Hcode::Tools::MediaKind::Unknown)
  end
end

describe "Hcode::Tools.sniff_image_dimensions" do
  it "reads PNG dimensions" do
    # Build a minimal PNG IHDR-like header.
    header = Bytes.new(24, 0)
    header[0] = 0x89
    header[1] = 0x50
    # 800x600 at IHDR offset.
    header[16] = 0
    header[17] = 0
    header[18] = 0x03
    header[19] = 0x20
    header[20] = 0
    header[21] = 0
    header[22] = 0x02
    header[23] = 0x58
    dims = Hcode::Tools.sniff_image_dimensions(header)
    dims.should_not be_nil
    dims.not_nil!.width.should eq(800)
    dims.not_nil!.height.should eq(600)
  end

  it "reads GIF dimensions" do
    header = Bytes.new(13, 0)
    header[0] = 0x47
    header[1] = 0x49
    header[6] = 0x20
    header[8] = 0x58
    dims = Hcode::Tools.sniff_image_dimensions(header)
    dims.should_not be_nil
    dims.not_nil!.width.should eq(0x20)
    dims.not_nil!.height.should eq(0x58)
  end
end

describe "Hcode::Tools.format_byte_size" do
  it "formats bytes" do
    Hcode::Tools.format_byte_size(500).should eq("500B")
    Hcode::Tools.format_byte_size(1023).should eq("1023B")
  end

  it "formats KiB" do
    Hcode::Tools.format_byte_size(2048).should eq("2.0KiB")
    Hcode::Tools.format_byte_size(1536).should eq("1.5KiB")
  end

  it "formats MiB" do
    Hcode::Tools.format_byte_size(2 * 1024 * 1024).should eq("2.0MiB")
  end
end

# Fake in-memory FS for tool tests.
class FakeMediaFS < Hcode::Tools::MediaFileSystem
  getter files : Hash(String, Bytes)

  def initialize
    @files = {} of String => Bytes
  end

  def add(path : String, data : Bytes) : Nil
    @files[path] = data
  end

  def read(path : String) : Bytes
    @files[path]
  end

  def size(path : String) : Int64
    @files[path].size.to_i64
  end

  def exists?(path : String) : Bool
    @files.has_key?(path)
  end
end

def make_png(width : Int32, height : Int32) : Bytes
  header = Bytes.new(24, 0)
  # Full PNG magic bytes.
  header[0] = 0x89
  header[1] = 0x50
  header[2] = 0x4E
  header[3] = 0x47
  header[4] = 0x0D
  header[5] = 0x0A
  header[6] = 0x1A
  header[7] = 0x0A
  # 4-byte BE width/height at offset 16.
  header[16] = (width >> 24).to_u8
  header[17] = (width >> 16).to_u8
  header[18] = (width >> 8).to_u8
  header[19] = width.to_u8
  header[20] = (height >> 24).to_u8
  header[21] = (height >> 16).to_u8
  header[22] = (height >> 8).to_u8
  header[23] = height.to_u8
  header
end

describe Hcode::Tools::ReadMediaFile do
  before_each do
    Hcode::Tools::Media.fs = FakeMediaFS.new
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: true, video_in: false)
    Hcode::Tools::Media.image_processor = Hcode::Tools::PassThroughImageProcessor.new
  end
  after_each do
    Hcode::Tools::Media.fs = nil
    Hcode::Tools::Media.capabilities = nil
    Hcode::Tools::Media.image_processor = nil
  end

  it "exposes JS-name and identical schema" do
    tool = Hcode::Tools::ReadMediaFile.new
    tool.name.should eq("ReadMediaFile")
    props = tool.parameters["properties"].as_h
    props.has_key?("path").should be_true
    props.has_key?("region").should be_true
    props.has_key?("full_resolution").should be_true
    tool.parameters["required"].as_a.map(&.as_s).should eq(["path"])
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "rejects empty path" do
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("cannot be empty")
  end

  it "rejects non-existent file" do
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "/nope.png" })))
    result.is_error?.should be_true
    result.content.should contain("does not exist")
  end

  it "rejects text files" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    fs.add("test.txt", "hello world\nthis is text".to_slice)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "test.txt" })))
    result.is_error?.should be_true
    result.content.should contain("text file")
    result.content.should contain("Use Read")
  end

  it "rejects unknown binary" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    fs.add("blob.bin", Bytes[0x00, 0x01, 0x02, 0x03, 0xFF])
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "blob.bin" })))
    result.is_error?.should be_true
    result.content.should contain("not a supported")
  end

  it "rejects image when model lacks image_in capability" do
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: false, video_in: false)
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    fs.add("img.png", make_png(100, 100))
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "img.png" })))
    result.is_error?.should be_true
    result.content.should contain("does not support image input")
  end

  it "rejects video when model lacks video_in capability" do
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: false, video_in: false)
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    # MP4 header
    mp4_header = Bytes[0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00]
    fs.add("v.mp4", mp4_header)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "v.mp4" })))
    result.is_error?.should be_true
    result.content.should contain("does not support video input")
  end

  it "rejects region/full_resolution on video" do
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: false, video_in: true)
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    mp4_header = Bytes[0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x00, 0x00]
    fs.add("v.mp4", mp4_header)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "v.mp4", "region": { "x": 0, "y": 0, "width": 10, "height": 10 } })))
    result.is_error?.should be_true
    result.content.should contain("apply only to image files")
  end

  it "reads PNG image as base64 data URL with <system> note" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    fs.add("img.png", make_png(100, 200))
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "img.png" })))
    result.is_error?.should be_false
    result.content.should contain("<image path=\"img.png\">")
    result.content.should contain("</image>")
    result.content.should contain("data:image/png;base64,")
    result.content.should contain("<system>")
    result.content.should contain("Mime type: image/png.")
    result.content.should contain("Original dimensions: 100x200 pixels.")
    result.content.should contain("</system>")
  end

  it "rejects oversized file > 100MB" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    # 100MB + 1 byte
    big = Bytes.new(Hcode::Tools::Media::MAX_MEDIA_BYTES + 1, 0x89)
    big[0] = 0x89
    big[1] = 0x50
    fs.add("big.png", big)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "big.png" })))
    result.is_error?.should be_true
    result.content.should contain("exceeds the maximum 100MB")
  end

  it "rejects empty file" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    fs.add("empty.png", Bytes.empty)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "empty.png" })))
    result.is_error?.should be_true
    result.content.should contain("empty")
  end

  it "rejects full_resolution when file > IMAGE_BYTE_BUDGET" do
    fs = Hcode::Tools::Media.fs.as(FakeMediaFS)
    # Build a synthetic PNG that's bigger than IMAGE_BYTE_BUDGET.
    big = Bytes.new(Hcode::Tools::Media::IMAGE_BYTE_BUDGET + 100, 0)
    big[0] = 0x89
    big[1] = 0x50
    big[2] = 0x4E
    big[3] = 0x47
    big[4] = 0x0D
    big[5] = 0x0A
    big[6] = 0x1A
    big[7] = 0x0A
    fs.add("big.png", big)
    tool = Hcode::Tools::ReadMediaFile.new
    result = tool.execute(JSON.parse(%({ "path": "big.png", "full_resolution": true })))
    result.is_error?.should be_true
    result.content.should contain("so full_resolution cannot be honored")
  end

  it "renders capability tail with both inputs supported" do
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: true, video_in: true)
    tool = Hcode::Tools::ReadMediaFile.new
    tool.description.should contain("supports image and video files")
  end

  it "renders capability tail with image only" do
    Hcode::Tools::Media.capabilities = Hcode::Tools::ModelCapabilities.new(image_in: true, video_in: false)
    tool = Hcode::Tools::ReadMediaFile.new
    tool.description.should contain("supports image files")
    tool.description.should contain("Video files are not supported")
  end
end
