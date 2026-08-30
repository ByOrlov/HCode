require "spec"
require "../src/version_compare"

describe H2code::VersionCompare do
  describe ".compare" do
    it "ranks by build number within the same day" do
      H2code::VersionCompare.compare("2026.07.31.1", "2026.07.31.2").should be < 0
      H2code::VersionCompare.compare("2026.07.31.3", "2026.07.31.1").should be > 0
    end

    it "ranks by date when build numbers are equal" do
      H2code::VersionCompare.compare("2026.07.30.1", "2026.07.31.1").should be < 0
      H2code::VersionCompare.compare("2026.08.01.1", "2026.07.31.1").should be > 0
    end

    it "ranks across months and years" do
      H2code::VersionCompare.compare("2026.12.31.9", "2027.01.01.1").should be < 0
    end

    it "returns zero for equal versions" do
      H2code::VersionCompare.compare("2026.07.31.1", "2026.07.31.1").should eq(0)
    end

    it "treats a missing build number as 0" do
      H2code::VersionCompare.compare("2026.07.31", "2026.07.31.0").should eq(0)
      H2code::VersionCompare.compare("2026.07.31", "2026.07.31.1").should be < 0
    end
  end

  describe ".newer?" do
    it "is true when candidate is strictly greater" do
      H2code::VersionCompare.newer?("2026.07.31.2", "2026.07.31.1").should be_true
    end

    it "is false when candidate equals current" do
      H2code::VersionCompare.newer?("2026.07.31.1", "2026.07.31.1").should be_false
    end

    it "is false when candidate is older" do
      H2code::VersionCompare.newer?("2026.07.30.1", "2026.07.31.1").should be_false
    end
  end
end
