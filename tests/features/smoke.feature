Feature: The feature runner runs

  Scenario: Bytes are counted
    Given nothing has been sent
    When 3 bytes are sent
    And 4 bytes are sent
    Then 7 bytes have been sent
