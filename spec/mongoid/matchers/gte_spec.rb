require "spec_helper"

describe Mongoid::Matchers::Gte do

  describe "#matches?" do

    context "when the value is larger" do

      let(:matcher) do
        Mongoid::Matchers::Gte.new(5)
      end

      it "returns true" do
        matcher.matches?("$gte" => 3).should be_true
      end
    end

    context "when the value is smaller" do

      let(:matcher) do
        Mongoid::Matchers::Gte.new(5)
      end

      it "returns false" do
        matcher.matches?("$gte" => 10).should be_false
      end
    end

    context "when the value is equal" do

      let(:matcher) do
        Mongoid::Matchers::Gte.new(5)
      end

      it "returns true" do
        matcher.matches?("$gte" => 5).should be_true
      end
    end

    context "when the value is nil" do

      let(:matcher) do
        Mongoid::Matchers::Gte.new(nil)
      end

      it "returns false" do
        matcher.matches?("$gte" => 5).should be_false
      end
    end
  end
end
