require "test_helper"

class ParentsControllerTest < ActionDispatch::IntegrationTest
  test "renders the info page for parents and guardians" do
    get info_url
    assert_response :success
    assert_select "h1", "Understanding the Hack Club NDA"
    assert_select "section.parents-disclaimer"
    assert_select "a[href='#{login_path}']", "Sign in to view agreement"
  end

  test "parents route is removed and raises routing error or 404" do
    assert_raises(ActionController::RoutingError) do
      get "/parents"
    end
  end

  test "renders sign page link when signed in" do
    get oauth_callback_url(code: "auth-code", state: "test-state")
    session[:user_id] = users(:one).id

    get info_url
    assert_response :success
    assert_select "a[href='#{nda_signature_path}']", "Go to NDA Signing Page"
  end
end
