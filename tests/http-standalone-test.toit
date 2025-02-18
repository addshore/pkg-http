// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/TESTS_LICENSE file.

import encoding.json
import encoding.url
import expect show *
import http
import http.connection show is_close_exception_
import io
import net

import .cat

// Sets up a web server on localhost and connects to it.

main:
  network := net.open
  port := start_server network
  run_client network port

POST_DATA ::= {
    "foo": "bar",
    "date": "2023-04-25",
    "baz": "42?103",
    "/&%": "slash",
    "slash": "/&%"
}

class NonSizedTestReader extends io.Reader:
  call_count_ := 0
  chunks_ := List 5: "$it" * it

  read_ -> ByteArray?:
    if call_count_ == chunks_.size:
      return null
    call_count_++
    return chunks_[call_count_ - 1].to_byte_array

  full_data -> ByteArray:
    return (chunks_.join "").to_byte_array

run_client network port/int -> none:
  client := http.Client network

  connection := null

  2.repeat:

    response := client.get --host="localhost" --port=port --path="/"

    if connection:
      expect_equals connection client.connection_  // Check we reused the connection.
    else:
      connection = client.connection_

    page := ""
    while data := response.body.read:
      page += data.to_string
    expect_equals INDEX_HTML.size page.size

    response = client.get --host="localhost" --port=port --path="/cat.png"
    expect_equals connection client.connection_  // Check we reused the connection.
    expect_equals "image/png"
        response.headers.single "Content-Type"
    size := 0
    while data := response.body.read:
      size += data.size

    expect_equals CAT.size size

    response = client.get --host="localhost" --port=port --path="/unobtainium.jpeg"
    expect_equals connection client.connection_  // Check we reused the connection.
    expect_equals 404 response.status_code

    response = client.get --uri="http://localhost:$port/204_no_content"
    expect_equals 204 response.status_code
    expect_equals "Nothing more to say" (response.headers.single "X-Toit-Message")

    response = client.get --host="localhost" --port=port --path="/foo.json"
    expect_equals connection client.connection_  // Check we reused the connection.

    expect_json response:
      expect_equals 123 it["foo"]

  // Try to buffer the whole response.
  response := client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  response.body.buffer-all
  bytes := response.body.read-all
  decoded := json.decode bytes
  expect_equals 123 decoded["foo"]

  response = client.get --uri="http://localhost:$port/content-length.json"
  expect_equals 200 response.status_code
  expect_equals "application/json"
      response.headers.single "Content-Type"
  content-length := response.headers.single "Content-Length"
  expect_not_null content-length
  expect_json response:
    expect_equals 123 it["foo"]

  // Try to buffer the whole response.
  response = client.get --uri="http://localhost:$port/content-length.json"
  expect_equals 200 response.status_code
  response.body.buffer-all
  bytes = response.body.read-all
  decoded = json.decode bytes
  expect_equals 123 decoded["foo"]

  response = client.get --uri="http://localhost:$port/redirect_back"
  expect connection != client.connection_  // Because of the redirect we had to make a new connection.
  expect_equals "application/json"
      response.headers.single "Content-Type"
  expect_json response:
    expect_equals 123 it["foo"]

  expect_throw "Too many redirects": client.get --uri="http://localhost:$port/redirect_loop"

  response = client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  response.drain

  connection = client.connection_

  response = client.get --uri="http://localhost:$port/500_because_nothing_written"
  expect_equals 500 response.status_code

  expect_equals connection client.connection_  // Check we reused the connection.

  response = client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  expect_equals connection client.connection_  // Check we reused the connection.
  response.drain

  response2 := client.get --uri="http://localhost:$port/500_because_throw_before_headers"
  expect_equals 500 response2.status_code

  expect_equals connection client.connection_  // Check we reused the connection.

  response = client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  expect_equals connection client.connection_  // Check we reused the connection.
  response.drain

  exception3 := catch --trace=(: not is_close_exception_ it):
    response3 := client.get --uri="http://localhost:$port/hard_close_because_wrote_too_little"
    if 200 <= response3.status_code <= 299:
      while response3.body.read: null
  // TODO: This should be a smaller number of different exceptions and the
  // library should export a non-private method that recognizes them.
  expect (is_close_exception_ exception3)

  response = client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  // We will not be reusing the connection here because the server had to close it
  // after the user's router did not write enough data.
  expect_not_equals connection client.connection_  // Check we reused the connection.
  response.drain

  connection = client.connection_

  exception4 := catch --trace=(: not is_close_exception_ it):
    response4 := client.get --uri="http://localhost:$port/hard_close_because_throw_after_headers"
    if 200 <= response4.status_code <= 299:
      while response4.body.read: null
  expect (is_close_exception_ exception4)

  response = client.get --host="localhost" --port=port --path="/foo.json"
  expect_equals 200 response.status_code
  // We will not be reusing the connection here because the server had to close it
  expect
    is_close_exception_ exception4
  // after the user's router threw after writing success headers.
  expect_not_equals connection client.connection_  // Check we reused the connection.
  response.drain

  connection = client.connection_

  response5 := client.get --uri="http://localhost:$port/redirect_from"
  expect connection != client.connection_  // Because of two redirects we had to make two new connections.
  expect_json response5:
    expect_equals 123 it["foo"]

  data := {"foo": "bar", "baz": [42, 103]}

  response6 := client.post_json data --uri="http://localhost:$port/post_json"
  expect_equals "application/json"
      response6.headers.single "Content-Type"
  expect_json response6:
    expect_equals data["foo"] it["foo"]
    expect_equals data["baz"] it["baz"]

  response7 := client.post_json data --uri="http://localhost:$port/post_json_redirected_to_cat"
  expect_equals "image/png"
      response7.headers.single "Content-Type"
  round_trip_cat := #[]
  while byte_array := response7.body.read:
    round_trip_cat += byte_array
  expect_equals CAT round_trip_cat

  response8 := client.get --uri="http://localhost:$port/subdir/redirect_relative"
  expect_json response8:
    expect_equals 345 it["bar"]

  response9 := client.get --uri="http://localhost:$port/subdir/redirect_absolute"
  expect_json response9:
    expect_equals 123 it["foo"]

  request := client.new_request "HEAD" --host="localhost" --port=port --path="/foohead.json"
  response10 := request.send
  expect_equals 405 response10.status_code

  response11 := client.post_form --host="localhost" --port=port --path="/post_form" POST_DATA
  expect_equals 200 response11.status_code

  test_reader := NonSizedTestReader
  request = client.new_request "POST" --host="localhost" --port=port --path="/post_chunked"
  request.body = test_reader
  response12 := request.send
  expect_equals 200 response12.status_code
  response_data := #[]
  while chunk := response12.body.read:
    response_data += chunk
  expect_equals test_reader.full_data response_data

  response13 := client.get --host="localhost" --port=port --path="/get_with_parameters" --query_parameters=POST_DATA
  response_data = #[]
  while chunk := response13.body.read:
    response_data += chunk
  expect_equals "Response with parameters" response_data.to_string

  request = client.new_request "GET" --host="localhost" --port=port --path="/get_with_parameters" --query_parameters=POST_DATA
  response14 := request.send
  expect_equals 200 response14.status_code
  while chunk := response13.body.read:
    response_data += chunk
  expect_equals "Response with parameters" response_data.to_string

  client.close

expect_json response/http.Response [verify_block]:
  expect_equals "application/json"
      response.headers.single "Content-Type"
  crock := #[]
  while data := response.body.read:
    crock += data
  result := json.decode crock
  verify_block.call result

start_server network -> int:
  server_socket1 := network.tcp_listen 0
  port1 := server_socket1.local_address.port
  server1 := http.Server
  server_socket2 := network.tcp_listen 0
  port2 := server_socket2.local_address.port
  server2 := http.Server
  task --background::
    listen server1 server_socket1 port1 port2
  task --background::
    listen server2 server_socket2 port2 port1
  print ""
  print "Listening on http://localhost:$port1/"
  print "Listening on http://localhost:$port2/"
  print ""
  return port1


listen server server_socket my_port other_port:
  server.listen server_socket:: | request/http.RequestIncoming response_writer/http.ResponseWriter |
    if request.method == "POST" and request.path != "/post_chunked":
      expect_not_null (request.headers.single "Content-Length")

    resource := request.query.resource

    writer := response_writer.out
    if resource == "/":
      response_writer.headers.set "Content-Type" "text/html"
      writer.write INDEX_HTML
    else if resource == "/foo.json":
      response_writer.headers.set "Content-Type" "application/json"
      writer.write
        json.encode {"foo": 123, "bar": 1.0/3, "fizz": [1, 42, 103]}
    else if resource == "/content-length.json":
      data := json.encode {"foo": 123, "bar": 1.0/3, "fizz": [1, 42, 103]}
      response_writer.headers.set "Content-Type" "application/json"
      response_writer.headers.set "Content-Length" "$data.size"
      writer.write data
    else if resource == "/cat.png":
      response_writer.headers.set "Content-Type" "image/png"
      writer.write CAT
    else if resource == "/redirect_from":
      response_writer.redirect http.STATUS_FOUND "http://localhost:$other_port/redirect_back"
    else if resource == "/redirect_back":
      response_writer.redirect http.STATUS_FOUND "http://localhost:$other_port/foo.json"
    else if resource == "/subdir/redirect_relative":
      response_writer.redirect http.STATUS_FOUND "bar.json"
    else if resource == "/subdir/bar.json":
      response_writer.headers.set "Content-Type" "application/json"
      writer.write
        json.encode {"bar": 345 }
    else if resource == "/subdir/redirect_absolute":
      response_writer.redirect http.STATUS_FOUND "/foo.json"
    else if resource == "/redirect_loop":
      response_writer.redirect http.STATUS_FOUND "http://localhost:$other_port/redirect_loop"
    else if resource == "/204_no_content":
      response_writer.headers.set "X-Toit-Message" "Nothing more to say"
      response_writer.write_headers http.STATUS_NO_CONTENT
    else if resource == "/500_because_nothing_written":
      // Forget to write anything - the server should send 500 - Internal error.
    else if resource == "/500_because_throw_before_headers":
      throw "** Expect a stack trace here caused by testing: throws_before_headers **"
    else if resource == "/hard_close_because_wrote_too_little":
      response_writer.headers.set "Content-Length" "2"
      writer.write "x"  // Only writes half the message.
    else if resource == "/hard_close_because_throw_after_headers":
      response_writer.headers.set "Content-Length" "2"
      writer.write "x"  // Only writes half the message.
      throw "** Expect a stack trace here caused by testing: throws_after_headers **"
    else if resource == "/post_json":
      response_writer.headers.set "Content-Type" "application/json"
      while data := request.body.read:
        writer.write data
    else if resource == "/post_form":
      expect_equals "application/x-www-form-urlencoded" (request.headers.single "Content-Type")
      response_writer.headers.set "Content-Type" "text/plain"
      str := ""
      while data := request.body.read:
        str += data.to_string
      map := {:}
      str.split "&": | pair |
        parts := pair.split "="
        key := url.decode parts[0]
        value := url.decode parts[1]
        map[key.to_string] = value.to_string
      expect_equals POST_DATA.size map.size
      POST_DATA.do: | key value |
        expect_equals POST_DATA[key] map[key]
      writer.write "OK"
    else if resource == "/post_json_redirected_to_cat":
      response_writer.headers.set "Content-Type" "application/json"
      while data := request.body.read:
      response_writer.redirect http.STATUS_SEE_OTHER "http://localhost:$my_port/cat.png"
    else if resource == "/post_chunked":
      response_writer.headers.set "Content-Type" "text/plain"
      while data := request.body.read:
        writer.write data
    else if request.query.resource == "/get_with_parameters":
      response_writer.headers.set "Content-Type" "text/plain"
      writer.write "Response with parameters"
      POST_DATA.do: | key/string value/string |
        expect_equals value request.query.parameters[key]
    else:
      print "request.query.resource = '$request.query.resource'"
      response_writer.write_headers http.STATUS_NOT_FOUND --message="Not Found"
