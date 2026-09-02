defmodule MewtwoWeb.PageController do
  use MewtwoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
