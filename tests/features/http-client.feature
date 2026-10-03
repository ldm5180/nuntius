Feature: The HTTP clients report every failure and never raise

  Nuntius.Http's adapters answer a transport failure with Ok False and
  Status 0 on every verb, never an exception, and name themselves on
  the wire.  Port 9 on loopback is as close to a guaranteed refusal as
  there is without a network.

  Scenario Outline: A refused connection is a transport failure on every verb
    When the curl client sends a <verb> to a refused loopback port
    Then the response is a transport failure

    Examples:
      | verb      |
      | GET       |
      | DELETE    |
      | JSON-POST |
      | JSON-PUT  |
      | form-POST |

  Scenario: The registered identity reaches the wire
    Given the User-Agent is "probe/1.2"
    When the curl client sends a GET to a recording peer
    Then the response status is 200
    And the request on the wire carried "User-Agent: probe/1.2"

  Scenario: The async client names itself too
    Given the User-Agent is "probe/1.2"
    When the async client sends a GET to a recording peer
    Then the completion status is 200
    And the request on the wire carried "User-Agent: probe/1.2"

  Scenario: An idle async client pumps nothing
    When the async client pumps once
    Then no completion surfaced
    And the async client has 0 transfers in flight

  Scenario: A cancelled transfer never surfaces
    When the async client starts a GET to a refused loopback port
    And the async client cancels it
    And the async client pumps once
    Then no completion surfaced
    And the async client has 0 transfers in flight

  Scenario: A refused transfer surfaces as a failure, promptly
    When the async client starts a POST to a refused loopback port
    And the async client pumps and waits until it completes
    Then the completion is a transport failure
    And it surfaced within 3 seconds

  Scenario: The in-flight table is bounded
    When the async client fills its table with GETs to a refused loopback port
    Then one more start is refused
    And every started transfer completes
