# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require tdbc
package require tdbc::sqlite3

package require tpersist

#puts "Create DB..."

set db_backend [::tdbc::sqlite3::connection new ":memory:"]

::tpersist::Database create MyDB $db_backend

#puts "Define..."

oo::class create User {
    superclass [MyDB entityclass]

    PrimaryKey id         integer -auto 1
    Required   created_at datetime
    Required   type       string  -default "user"
    Required   status     bool    -default 1
    Required   username   string
    Required   password   string
    Required   email      string
    Required   rating     integer -default 0
    Set        votes      Vote
    Set        viewed     View
    Set        messages   Message
    Set        moderates  Section
}

oo::class create Message {
    superclass [MyDB entityclass]

    PrimaryKey id         integer -auto 1
    Required   text       string
    Required   rating     integer -default 0
    Set        votes      Vote
    Set        viewed     View
    Required   author     User
    Required   created_at datetime
    Optional   updated_at datetime
}

oo::class create Tag {
    superclass [MyDB entityclass]

    PrimaryKey id    integer -auto 1
    Required   name  string  -unique 1
    Set        posts Post
}

oo::class create Comment {
    superclass Message

    Required post Post
}

oo::class create Section {
    superclass [MyDB entityclass]

    PrimaryKey id         integer -auto 1
    Set        posts      Post
    Required   name       string
    Set        moderators User
}

oo::class create Vote {
    superclass [MyDB entityclass]

    PrimaryKey id         integer -auto 1
    Required   user       User
    Required   message    Message
    Required   value      integer
    Required   created_at datetime
}

oo::class create Post {
    superclass Message

    Required title    string
    Set      comments Comment
    Required section  Section
    Set      tags     Tag
}

oo::class create View {
    superclass [MyDB entityclass]

    PrimaryKey id             integer -auto 1
    Required   last_viewed_at datetime
    Required   user           User
    Required   message        Message
}

#puts "Create mapping..."

puts [MyDB generate_mapping]

#puts "Create a session..."

::tpersist::session new

puts "Create objects..."

set u1 [User new -created_at 123 -email "blblb@mail.com" -password foo -username john]
set s1 [Section new -name "bar"]
set p1 [Post new -title "foo" -section $s1 -author $u1 -created_at 123 -text "abcd fkj"]

#set u1 [User new -email "foo@mail.com"]
#set u2 [User new -email "bar@mail.com"]

puts "Flush the session..."

::tpersist::session done

puts "Done."

foreach table [dict keys [$db_backend tables]] {
    if { $table in {sqlite_sequence} } continue
    puts "\n### table: $table"
    set columns [lsort [dict keys [$db_backend columns $table]]]
    puts [join $columns " | "]
    foreach row [$db_backend allrows "SELECT * FROM $table"] {
        set row [lsort -stride 2 -index 0 $row]
        set row [dict values $row]
        puts [join $row " | "]
    }
}
