require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  setup do
    @original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rack::Attack.cache.store = @original_store
  end

  test "allows ten requests per second from an IP then throttles it" do
    travel_to Time.zone.at(1_700_000_000) do
      10.times do
        get root_url
        assert_response :success
      end

      get root_url
      assert_response :too_many_requests
      assert_equal "1", response.headers["Retry-After"]

      get root_url, headers: { "REMOTE_ADDR" => "192.0.2.2" }
      assert_response :success
    end
  end

  test "API responses report the live IP budget including errors and throttling" do
    travel_to Time.zone.at(1_700_000_000) do
      get root_url
      get api_v1_nda_status_url("U0123ABCDEF")
      assert_response :success
      assert_quota remaining: 8
      assert_nil response.headers["Retry-After"]

      get api_v1_nda_status_url("invalid")
      assert_response :bad_request
      assert_quota remaining: 7

      7.times { get api_v1_nda_status_url("U0123ABCDEF") }
      assert_response :success
      assert_quota remaining: 0
      assert_nil response.headers["Retry-After"]

      2.times do
        get api_v1_nda_status_url("U0123ABCDEF")
        assert_response :too_many_requests
        assert_quota remaining: 0
        assert_equal "1", response.headers["Retry-After"]
        assert_equal "Retry later\n", response.body
      end

      get api_v1_nda_status_url("U0123ABCDEF"), headers: { "REMOTE_ADDR" => "192.0.2.2" }
      assert_response :success
      assert_quota remaining: 9

      travel 1.second
      get api_v1_nda_status_url("U0123ABCDEF")
      assert_response :success
      assert_quota remaining: 9
    end
  end

  private

  def assert_quota(remaining:)
    assert_equal "10", response.headers["RateLimit-Limit"]
    assert_equal remaining.to_s, response.headers["RateLimit-Remaining"]
    assert_equal "1", response.headers["RateLimit-Reset"]
    assert_equal '"requests-per-ip";q=10;w=1', response.headers["RateLimit-Policy"]
    assert_equal %Q("requests-per-ip";r=#{remaining};t=1), response.headers["RateLimit"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end
end
