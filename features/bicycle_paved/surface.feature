@routing @surface @bicycle_paved
Feature: Bicycle paved - Surfaces

    Background:
        Given the profile "bicycle_paved"

    Scenario: Roads may omit their surface but cycleways may not
        Then routability should be
            | highway | surface | bothw |
            | primary |         | x     |
            | primary | unknown | x     |
            | primary | mud     |       |
            | cycleway |         |       |
            | cycleway | unknown |       |
            | cycleway | asphalt | x     |
