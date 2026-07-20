@routing @bicycle_paved @cycleway_preference
Feature: Bicycle paved - cycleway preference

    Background:
        Given the profile "bicycle_paved"
        Given a grid size of 100 meters

    Scenario: An ordinary cycleway has the same per-distance weight as a normal road
        Given the node map
            """
            a b
            c d
            """

        And the ways
            | nodes | highway     | surface | smoothness | name      |
            | ab    | cycleway    | asphalt | good       | Cycleway  |
            | cd    | residential | asphalt |            | Road      |

        When I route I should get
            | from | to | weight |
            | a    | b  | 24     |
            | c    | d  | 24     |

    Scenario: An excellent-smoothness cycleway is effectively free
        Given the node map
            """
            a b c d e
              f     g
            """

        And the ways
            | nodes | highway     | surface | smoothness | name      |
            | abcde | cycleway    | asphalt | excellent  | Cycleway  |
            | afge  | residential | asphalt |            | Road      |

        When I route I should get
            | from | to | route             |
            | a    | e  | Cycleway,Cycleway |

    Scenario: A cycle-network relation makes a cycleway effectively free
        Given the node map
            """
            a b c d e
              f     g
            """

        And the ways
            | nodes | highway     | surface | smoothness | name      |
            | abcde | cycleway    | asphalt | good       | Cycleway  |
            | afge  | residential | asphalt |            | Road      |

        And the relations
            | type  | way   | route   | cycle_network              |
            | route | abcde | bicycle | UK:National Cycle Network  |

        When I route I should get
            | from | to | route             |
            | a    | e  | Cycleway,Cycleway |

    Scenario: A preferred cycleway still needs a permitted paved surface
        Then routability should be
            | highway   | surface | smoothness | maxspeed | bothw |
            | cycleway  | gravel  | excellent  |          |       |
            | cycleway  | asphalt | excellent  |          | x     |
            | secondary | asphalt |            | 120      |       |

    Scenario: Roads may omit their surface but cycleways may not
        Then routability should be
            | highway | surface  | bothw |
            | primary |          | x     |
            | primary | unknown  | x     |
            | primary | mud      |       |
            | cycleway |          |       |
            | cycleway | unknown  |       |
            | cycleway | asphalt  | x     |

    Scenario: Switching between a road and a separate cycleway has a small cost
        Given the node map
            """
            a b c
            """

        And the ways
            | nodes | highway   | surface | smoothness |
            | ab    | secondary | asphalt |            |
            | bc    | cycleway  | asphalt | excellent  |

        When I route I should get
            | from | to | weight      |
            | a    | c  | 26.1 +- 0.1 |
