defmodule Blink.ConfidenceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Blink.Confidence
  import Blink.Test.Fixtures, only: [token: 2]

  describe "from_logprobs/2" do
    test "computes the geometric mean of token probabilities" do
      entries = [token("a", -0.1), token("b", -0.2)]

      report = Confidence.from_logprobs(entries)

      assert_in_delta report.confidence, :math.exp(-0.15), 1.0e-12
      assert report.tokens_used == 2
      assert report.tokens_total == 2
      assert report.excluded == 0
      assert report.low_confidence? == false
    end

    test "flags low confidence below the default threshold" do
      entries = [token("a", -2.0), token("b", -2.0)]

      report = Confidence.from_logprobs(entries)

      assert_in_delta report.confidence, :math.exp(-2.0), 1.0e-12
      assert report.low_confidence? == true
    end

    test "returns nil confidence and low_confidence? for empty input" do
      report = Confidence.from_logprobs([])

      assert report.confidence == nil
      assert report.low_confidence? == true
      assert report.tokens_used == 0
      assert report.tokens_total == 0
      assert report.excluded == 0
    end

    test "excludes structural JSON tokens from the mean by default" do
      entries = [
        token("{", -1.0),
        token("intent", -0.1),
        token(": ", -1.0),
        token("simple_query", -0.2),
        token("}", -1.0)
      ]

      report = Confidence.from_logprobs(entries)

      assert report.tokens_used == 2
      assert report.tokens_total == 5
      assert report.excluded == 3
      assert_in_delta report.confidence, :math.exp(-0.15), 1.0e-12
    end

    test "includes structural tokens when :include_structural is true" do
      entries = [
        token("{", -1.0),
        token("intent", -0.1),
        token(": ", -1.0),
        token("simple_query", -0.2),
        token("}", -1.0)
      ]

      report = Confidence.from_logprobs(entries, include_structural: true)

      assert report.tokens_used == 5
      assert report.excluded == 0
      assert_in_delta report.confidence, :math.exp(-0.66), 1.0e-12
    end

    test "treats an all-structural response as uncalibratable" do
      report = Confidence.from_logprobs([token("{", -1.0), token("}", -1.0)])

      assert report.confidence == nil
      assert report.low_confidence? == true
      assert report.tokens_used == 0
      assert report.excluded == 2
    end

    test "excludes entries without a numeric logprob" do
      report = Confidence.from_logprobs([%{"token" => "x"}, %{"token" => "y", "logprob" => -0.5}])

      assert report.tokens_used == 1
      assert report.excluded == 1
      assert_in_delta report.confidence, :math.exp(-0.5), 1.0e-12
    end

    test "excludes non-map entries" do
      report = Confidence.from_logprobs(["garbage", token("x", -0.5)])

      assert report.tokens_used == 1
      assert report.excluded == 1
      assert_in_delta report.confidence, :math.exp(-0.5), 1.0e-12
    end

    test "keeps entries that have a logprob but no token" do
      report = Confidence.from_logprobs([%{"logprob" => -0.4}, token("x", -0.6)])

      assert report.tokens_used == 2
      assert report.excluded == 0
      assert_in_delta report.confidence, :math.exp(-0.5), 1.0e-12
    end

    test "accepts atom keys" do
      report = Confidence.from_logprobs([%{token: "x", logprob: -0.3}])

      assert_in_delta report.confidence, :math.exp(-0.3), 1.0e-12
      assert report.tokens_used == 1
    end

    test "applies a custom :threshold" do
      entries = [token("x", :math.log(0.75))]

      below = Confidence.from_logprobs(entries, threshold: 0.76)
      above = Confidence.from_logprobs(entries, threshold: 0.74)

      assert below.low_confidence? == true
      assert above.low_confidence? == false
      assert below.threshold == 0.76
      assert above.threshold == 0.74
    end

    test "records the default threshold in the report" do
      report = Confidence.from_logprobs([token("x", -0.1)])
      assert report.threshold == 0.75
    end

    test "realistic high-confidence fixture scores above threshold" do
      report = Confidence.from_logprobs(Blink.Test.Fixtures.high_confidence_tokens())

      assert report.confidence > 0.9
      assert report.low_confidence? == false
      assert report.tokens_used == 4
      assert report.excluded == 3
    end

    test "realistic low-confidence fixture scores below threshold" do
      report = Confidence.from_logprobs(Blink.Test.Fixtures.low_confidence_tokens())

      assert report.confidence < 0.75
      assert report.low_confidence? == true
    end
  end

  describe "structural_token?/1" do
    test "matches punctuation and whitespace only" do
      assert Confidence.structural_token?("{")
      assert Confidence.structural_token?("}")
      assert Confidence.structural_token?("]")
      assert Confidence.structural_token?("\"")
      assert Confidence.structural_token?(",")
      assert Confidence.structural_token?(":")
      assert Confidence.structural_token?("  ")
      assert Confidence.structural_token?(": ")
    end

    test "rejects tokens with letters or digits" do
      refute Confidence.structural_token?("intent")
      refute Confidence.structural_token?("true")
      refute Confidence.structural_token?("123")
      refute Confidence.structural_token?("\"intent\"")
    end

    test "rejects non-binary tokens" do
      refute Confidence.structural_token?(42)
      refute Confidence.structural_token?(nil)
      refute Confidence.structural_token?(:atom)
    end
  end
end
