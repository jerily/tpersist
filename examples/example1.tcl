# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require tpersist

puts "Create DB..."

::tpersist::DatabaseSqlite3 create MyDB -opt1 11 -opt2 22 -opt3 33

puts "Define..."

oo::class create Person {
    superclass [MyDB entityclass]

    Required email      string -unique 1
    Required password   string
    Required name       string
    Required country    string
    Required address    string
}

oo::class create Customer {
    superclass Person

    Required company    string
    Set      cart_items CartItem
    Set      orders     Order
}

oo::class create Order {
    superclass [MyDB entityclass]

    Required total_price  integer
    Required date_created date
    Required customer     Customer
}

oo::class create Employee {
    superclass Person

    Required department string
}

oo::class create Product {
    superclass [MyDB entityclass]

    Required name  string
    Required price integer
}

puts "Create mapping..."

puts [MyDB generate_mapping]

puts "Create a session..."

::tpersist::session new

puts "Create objects..."

set c1 [Customer new -email "foo@mail.com"]
set c2 [Customer new -email "bar@mail.com"]

puts "Flush the session..."

::tpersist::session done

puts "Done."

