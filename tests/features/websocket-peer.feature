Feature: A served websocket answers its browser as RFC 6455 says

  Nuntius.Ws.Peer is the server end of an adopted socket: it sends
  unmasked, pongs a ping, echoes a close, and closes on anything it
  will not read with a code that says why.  The browser end masks
  everything it sends, as a browser does.  This peer reads messages of
  at most 512 bytes; a deflated one also reads and sends packed ones.

  Scenario: The peer's text goes out unmasked
    Given a websocket pair
    When the peer sends "hi"
    Then the browser reads a text frame "hi"

  Scenario: A document past 64 KB goes out whole, in the 64-bit length form
    Given a websocket pair
    When the peer sends a 70000-byte message
    Then the browser reads a text frame of 70000 bytes

  Scenario: A whole text frame is a message
    Given a websocket pair
    When the browser sends the text {"token":"x"}
    And the peer pumps
    Then the pump outcome is message
    And the peer read what the browser sent

  Scenario: A ping is ponged, payload and all
    Given a websocket pair
    When the browser sends a ping "ab"
    And the peer pumps
    Then the pump outcome is nothing
    And the browser reads a pong "ab"

  Scenario: A close is echoed, and the peer shuts
    Given a websocket pair
    When the browser sends a close with code 1000
    And the peer pumps
    Then the pump outcome is closed
    And the browser reads a close with code 1000
    And the peer is shut

  Scenario: A hangup is a close, and a send after it fails
    Given a websocket pair
    When the browser hangs up
    And the peer pumps
    Then the pump outcome is closed
    And the peer is shut
    And a send from the peer fails

  Scenario Outline: A frame the peer will not read closes it, saying why
    Given a websocket pair
    When the browser sends <frame>
    And the peer pumps
    Then the pump outcome is faulted
    And the browser reads a close with code <code>

    Examples:
      | frame                      | code |
      | a 513-byte text message    | 1009 |
      | a binary frame             | 1003 |
      | a text frame with RSV1 set | 1002 |

  Scenario: A deflated peer reads a packed message to its cap, and a plain one
    Given a deflated websocket pair
    When the browser sends 512 bytes of JSON, packed
    And the peer pumps
    Then the pump outcome is message
    And the peer read what the browser sent
    When the browser sends the text {"token":"x"}
    And the peer pumps
    Then the peer read what the browser sent

  Scenario Outline: A packed frame the peer will not inflate closes it
    Given a deflated websocket pair
    When the browser sends <frame>
    And the peer pumps
    Then the pump outcome is faulted
    And the browser reads a close with code <code>

    Examples:
      | frame                                             | code |
      | 4096 zeros, packed                                | 1009 |
      | the bytes named corrupt-deflate as a packed frame | 1007 |
      | a ping with RSV1 set                              | 1002 |

  Scenario: A deflated peer sends packed text with RSV1 set
    Given a deflated websocket pair
    When the peer sends 2280 bytes of JSON, packed
    Then the browser reads a packed frame of what the peer packed

  Scenario: A plain peer sends text, whatever was packed for the others
    Given a websocket pair
    When the peer sends 2280 bytes of JSON, packed
    Then the browser reads a text frame of 2280 bytes
