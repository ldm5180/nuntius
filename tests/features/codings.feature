Feature: A body is compressed when the client takes it, and never otherwise

  With Coding_Policy => Compress_When_Offered, a text-like body of 512
  bytes or more, to a client that offers gzip, goes out gzipped with
  Vary: Accept-Encoding and the packed Content-Length.  Anything else
  goes out as it is.  The echo policy serves 2,220 bytes of JSON on
  /big, 100 of them on /small, and the same JSON typed image/png on
  /png.  Nuntius.Deflate is the one unit that calls zlib.

  Scenario: A big JSON body to a client that takes gzip is gzipped
    Given a serving loop that compresses when offered
    When the client sends a GET to /big
    And with header "Accept-Encoding: gzip, deflate, br"
    Then the reply carries "Content-Encoding: gzip"
    And the reply carries "Vary: Accept-Encoding"
    And the reply body gunzips to the big JSON
    And the reply's Content-Length is its body's

  Scenario: A client that offers nothing gets it plain
    Given a serving loop that compresses when offered
    When the client sends a GET to /big
    Then the reply carries no "Content-Encoding"
    And the reply body is the big JSON

  Scenario: A body under the floor goes plain
    Given a serving loop that compresses when offered
    When the client sends a GET to /small
    And with header "Accept-Encoding: gzip, deflate, br"
    Then the reply carries no "Content-Encoding"

  Scenario: An image goes plain
    Given a serving loop that compresses when offered
    When the client sends a GET to /png
    And with header "Accept-Encoding: gzip, deflate, br"
    Then the reply carries no "Content-Encoding"

  Scenario: The default policy never compresses
    Given a serving loop on loopback
    When the client sends a GET to /big
    And with header "Accept-Encoding: gzip, deflate, br"
    Then the reply carries no "Content-Encoding"
    And the reply body is the big JSON

  Scenario: Repetitive JSON gzips to under a tenth, and reads back
    When 3700 bytes of JSON are gzipped
    Then the result is under a tenth of them
    And zlib reads the result back whole

  Scenario: Noise still gzips, and reads back
    When 65536 bytes of noise are gzipped
    Then zlib reads the result back whole

  Scenario: A message past the floor packs small, and unpacks
    When 1850 bytes of JSON are packed
    Then the result is under a tenth of them
    And it unpacks to the same text

  Scenario Outline: Under 512 bytes a message is not packed
    When <length> bytes of JSON are packed
    Then <what> was packed

    Examples:
      | length | what      |
      | 511    | nothing   |
      | 512    | something |
