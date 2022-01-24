// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import http
import net
import encoding.json

URL ::= "httpbin.org"
PATH ::= "/post"

main:
  network := net.open
  client := http.Client network
  // The `post_json` method automatically closes the connection when
  // the response has been fully read.
  response := client.post_json --host=URL --path=PATH {
    "foo": 42,
    "bar": 499,
  }
  data := json.decode_stream response.body
  print data
