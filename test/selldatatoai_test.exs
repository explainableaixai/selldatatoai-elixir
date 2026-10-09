defmodule SellDataToAITest do
  use ExUnit.Case

  test "new/2 keeps options" do
    c = SellDataToAI.new("k", timeout: 5_000)
    assert c.timeout == 5_000
    assert c.base_url == "https://www.selldatatoai.com/api/v1"
  end

  test "submit_batch rejects empty and oversized lists before any request" do
    c = SellDataToAI.new("k")
    assert {:error, %SellDataToAI.Error{code: "bad_input"}} = SellDataToAI.submit_batch(c, [])
    many = for i <- 1..101, do: "d#{i}.com"
    assert {:error, %SellDataToAI.Error{code: "bad_input"}} = SellDataToAI.submit_batch(c, many)
  end

  test "transport errors come back as Error with status 0" do
    c = SellDataToAI.new("k", base_url: "http://127.0.0.1:1/v1", timeout: 2_000)
    assert {:error, %SellDataToAI.Error{status: 0}} = SellDataToAI.usage(c)
  end
end
