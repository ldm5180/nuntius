Feature: The websocket client keeps the port's contracts

  Nuntius.Ws.Native_Client against a scripted peer on loopback.  A
  reception is Delivered, Expired (a patient wait ran out, healthy) or
  Lost (reconnect-worthy).  The peer answers the upgrade, then sends
  its rows as one write up to each hold or ping, and hangs up.

  Scenario: A receive before any dial is lost, never a timeout
    Given a websocket client
    When the websocket client receives
    Then the reception is lost

  Scenario: A refused dial reports, and the client can dial again
    Given a websocket client
    When the websocket client dials a refused loopback port
    Then the dial fails
    When the websocket client dials a refused loopback port
    Then the dial fails

  Scenario: Messages arrive whole; a ping is ponged; a close is a loss
    Given a websocket client
    And a scripted websocket peer that sends:
      | kind         | text  |
      | text         | hello |
      | text-start   | foo   |
      | continuation | bar   |
      | ping         |       |
      | close        |       |
    When the websocket client connects
    And the websocket client receives
    Then the message is "hello"
    When the websocket client receives
    Then the message is "foobar"
    When the websocket client receives
    Then the reception is lost
    And the peer saw a pong

  Scenario: A burst glued to the handshake loses nothing
    Given a websocket client whose ring holds 128 frames of up to 16 bytes
    And a scripted websocket peer that sends:
      | kind  | text |
      | burst | 100  |
      | close |      |
    When the websocket client connects
    And the websocket client receives 100 messages
    Then every one was delivered, in order

  Scenario: A full ring drops the newest frames and keeps the connection
    Given a websocket client whose ring holds 4 frames of up to 256 bytes
    And a scripted websocket peer that sends:
      | kind  | text |
      | burst | 40   |
    When the websocket client connects
    And the websocket client receives
    Then the reception is delivered
    And the client counted dropped frames and no oversized one
    When the websocket client receives
    Then the reception is delivered

  Scenario: An oversized frame is a loss, counted with its length
    Given a websocket client whose ring holds 4 frames of up to 32 bytes
    And a scripted websocket peer that sends:
      | kind     | text |
      | oversize | 100  |
    When the websocket client connects
    And the websocket client receives
    Then the reception is lost
    And the client counted 1 oversized frame, the largest 100 bytes

  Scenario: A frame with RSV1 set is a loss, and no oversize
    Given a websocket client whose ring holds 4 frames of up to 32 bytes
    And a scripted websocket peer that sends:
      | kind | text |
      | rsv1 |      |
    When the websocket client connects
    And the websocket client receives
    Then the reception is lost
    And the client counted no oversized frame

  Scenario: A quiet line is a healthy timeout; the late frame still arrives
    Given a websocket client
    And a scripted websocket peer that sends:
      | kind  | text |
      | hold  | 1500 |
      | text  | late |
      | close |      |
    When the websocket client connects
    And the websocket client receives with 250 ms patience
    Then the reception is expired
    When the websocket client receives with 5000 ms patience
    Then the message is "late"
    When the websocket client receives with 5000 ms patience
    Then the reception is lost

  @slow
  Scenario: Silence past the idle limit is a loss, across patient receives
    Given a websocket client that gives up after 1 second of silence
    And a scripted websocket peer that sends:
      | kind  | text |
      | hold  | 2500 |
      | close |      |
    When the websocket client connects
    And the websocket client receives with 250 ms patience until it is lost
    Then it was lost within 8 receives, after at least 2 healthy timeouts
