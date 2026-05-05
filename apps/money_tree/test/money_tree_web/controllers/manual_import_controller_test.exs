defmodule MoneyTreeWeb.ManualImportControllerTest do
  use MoneyTreeWeb.ConnCase

  import MoneyTree.AccountsFixtures

  alias MoneyTree.XLSXFixture
  alias MoneyTreeWeb.Auth

  @session_cookie Auth.session_cookie_name()

  describe "manual import API" do
    test "creates, parses, commits, and rolls back a manual import batch", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      account = account_fixture(user, %{name: "Import checking"})

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn =
        post(authed_conn, ~p"/api/manual-imports", %{
          "account_id" => account.id,
          "source_institution" => "generic_csv",
          "file_name" => "sample.csv"
        })

      assert %{"data" => %{"id" => batch_id, "status" => "uploaded"}} =
               json_response(create_conn, 201)

      parse_conn =
        post(authed_conn, ~p"/api/manual-imports/#{batch_id}/parse", %{
          "csv_content" => """
          Date,Description,Amount,Status
          2026-04-20,Coffee,-5.25,Posted
          2026-04-21,Payroll,2000.00,Posted
          """,
          "mapping_config" => %{
            "columns" => %{
              "posted_at" => "Date",
              "description" => "Description",
              "amount" => "Amount",
              "status" => "Status"
            }
          }
        })

      assert %{
               "data" => %{
                 "rows_inserted" => 2,
                 "batch" => %{"id" => ^batch_id, "status" => "parsed", "row_count" => 2}
               }
             } = json_response(parse_conn, 200)

      rows_conn = get(authed_conn, ~p"/api/manual-imports/#{batch_id}/rows")
      assert %{"data" => [row1, row2]} = json_response(rows_conn, 200)
      assert row1["description"] == "Coffee"
      assert row2["description"] == "Payroll"

      commit_conn = post(authed_conn, ~p"/api/manual-imports/#{batch_id}/commit")

      assert %{
               "data" => %{
                 "id" => ^batch_id,
                 "status" => "committed",
                 "committed_count" => 2
               }
             } = json_response(commit_conn, 200)

      rollback_conn = post(authed_conn, ~p"/api/manual-imports/#{batch_id}/rollback")

      assert %{
               "data" => %{
                 "id" => ^batch_id,
                 "status" => "rolled_back",
                 "committed_count" => 0
               }
             } = json_response(rollback_conn, 200)
    end

    test "returns validation errors when mapping is missing required fields", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      account = account_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn = post(authed_conn, ~p"/api/manual-imports", %{"account_id" => account.id})
      %{"data" => %{"id" => batch_id}} = json_response(create_conn, 201)

      parse_conn =
        post(authed_conn, ~p"/api/manual-imports/#{batch_id}/parse", %{
          "csv_content" => "Date,Description,Amount\n2026-04-20,Coffee,-5.00\n",
          "mapping_config" => %{
            "columns" => %{
              "posted_at" => "Date",
              "amount" => "Amount"
            }
          }
        })

      assert json_response(parse_conn, 422) == %{"error" => "description mapping is required"}
    end

    test "parses xlsx file uploads", %{conn: conn} do
      user = user_fixture()
      %{token: token} = session_fixture(user)
      account = account_fixture(user)

      authed_conn = put_req_header(conn, "cookie", "#{@session_cookie}=#{token}")

      create_conn = post(authed_conn, ~p"/api/manual-imports", %{"account_id" => account.id})
      %{"data" => %{"id" => batch_id}} = json_response(create_conn, 201)

      xlsx =
        XLSXFixture.simple_workbook_binary([
          ["Date", "Description", "Amount", "Status"],
          ["2026-04-20", "Coffee", -5.25, "Posted"]
        ])

      upload = write_temp_upload!("sample.xlsx", xlsx)

      parse_conn =
        post(authed_conn, ~p"/api/manual-imports/#{batch_id}/parse", %{
          "file" => upload,
          "mapping_config" => %{
            "columns" => %{
              "posted_at" => "Date",
              "description" => "Description",
              "amount" => "Amount",
              "status" => "Status"
            }
          }
        })

      assert %{
               "data" => %{
                 "rows_inserted" => 1,
                 "batch" => %{"id" => ^batch_id, "status" => "parsed", "row_count" => 1}
               }
             } = json_response(parse_conn, 200)
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/manual-imports")
      assert conn.status == 401
    end
  end

  defp write_temp_upload!(file_name, content) do
    path =
      System.tmp_dir!()
      |> Path.join("moneytree-test-#{System.unique_integer([:positive])}-#{file_name}")

    File.write!(path, content)

    %Plug.Upload{
      path: path,
      filename: file_name,
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }
  end
end
