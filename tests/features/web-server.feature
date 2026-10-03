Feature: The serving loop answers every request it is sent

  Nuntius.Web.Server parses each request and hands the well-formed
  GET or POST to the consumer's Handle; everything else it answers
  itself, before Handle runs.  The handler here echoes
  "hi:<method>:<target>:<body>".

  Background:
    Given a serving loop on loopback

  Scenario: A GET reaches the handler with an empty payload
    When the client sends a GET to /x
    Then the reply status is 200
    And the handler received "hi:GET:/x:"

  Scenario: A method that is neither GET nor POST is refused, not misread
    When the client sends a PUT to /x
    Then the reply status is 405
    And the reply carries "method not allowed"

  Scenario: A malformed request line is refused
    When the client sends "garbage"
    Then the reply status is 400

  Scenario: A GET that brought a body is refused unread
    When the client sends a GET to /x
    And with the body abcde
    Then the reply status is 400
    And the reply carries "no body on GET"

  Scenario: A POST with no length is refused
    When the client sends a POST to /api/close
    Then the reply status is 400
    And the reply carries "length required"

  Scenario: A body over the cap is refused before it is read
    When the client sends a POST to /api/close
    And with header "Content-Length: 5000"
    Then the reply status is 413
    And the reply carries "body too large"

  Scenario: A JSON POST reaches the handler with its body
    When the client sends a POST to /api/close
    And with header "Content-Type: application/json"
    And with the body {"scope":"all"}
    Then the reply status is 200
    And the handler received "hi:POST:/api/close:{"
    And the handler echoed the request

  Scenario: A body that arrives in a second write still reaches the handler
    When the client sends a POST to /api/close
    And with the body {"scope":"all"}
    And with the body arriving 200 ms later
    Then the reply status is 200
    And the handler echoed the request
    And the handler saw 1 request

  Scenario: Half a head, then a hangup, is dropped quietly
    When the client sends half a head and hangs up
    Then no reply arrives
    And the handler saw 0 requests

  @slow
  Scenario: A dribble is ended by the connection budget
    Given a serving loop with a 1-second connection budget
    When the client dribbles one byte every 300 ms
    Then no reply arrives
    And the handler saw 0 requests
