defmodule WillyWeb.PageControllerTest do
  use WillyWeb.ConnCase

  test "GET / renders the game", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Willy 10"
  end
end
