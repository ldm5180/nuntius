Feature: A websocket upgrade is adopted or refused

  An upgrade the consumer accepts is answered 101 and its socket handed
  to Adopt, which the loop never touches again; one the consumer
  declines reaches Handle like any other request.  This consumer takes
  upgrades on /api/stream and answers a declined one 503.

  Scenario: An upgrade the consumer takes is answered 101 and adopted once
    Given a serving loop that takes upgrades on /api/stream
    When the client upgrades to /api/stream
    Then the reply status is 101
    And the socket was adopted plain
    And the handler saw 0 requests

  Scenario: An upgrade the consumer declines reaches the handler
    Given a serving loop that takes upgrades on /api/stream
    When the client upgrades to /elsewhere
    Then the reply status is 503
    And no socket was adopted
    And the handler saw it as an upgrade

  Scenario: A plain GET on the stream path is the GET it always was
    Given a serving loop that takes upgrades on /api/stream
    When the client sends a GET to /api/stream
    Then the reply status is 426
    And the reply carries "Upgrade: websocket"
    And no socket was adopted
    And the handler saw 1 request
    And the handler did not see an upgrade

  Scenario: A deflate offer is agreed, and Adopt is told
    Given a serving loop that compresses when offered and takes upgrades on /api/stream
    When the client upgrades to /api/stream offering "permessage-deflate; client_max_window_bits"
    Then the reply status is 101
    And the reply carries "Sec-WebSocket-Extensions: permessage-deflate"
    And the socket was adopted deflated

  Scenario: No offer, no extension
    Given a serving loop that compresses when offered and takes upgrades on /api/stream
    When the client upgrades to /api/stream
    Then the reply carries no "Sec-WebSocket-Extensions"
    And the socket was adopted plain

  Scenario: The default policy never agrees one
    Given a serving loop that takes upgrades on /api/stream
    When the client upgrades to /api/stream offering "permessage-deflate"
    Then the reply carries no "Sec-WebSocket-Extensions"
    And the socket was adopted plain
