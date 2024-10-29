# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require tdbc
package require tdbc::sqlite3

package require tpersist

#puts "Create DB..."

# set db_file "demo.sqlite3"
set db_file ":memory:"

set db_exists [file exists $db_file]

set db_backend [::tdbc::sqlite3::connection new $db_file]

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

if { $db_exists } {
    puts "Use existing data..."
} else {
    puts "Create mapping..."
    MyDB generate_mapping
}

if { !$db_exists } {

    #puts "Create a session..."

    ::tpersist::session new

    puts "Create objects..."

    set s1 [Section new -name "bar"]
    set s2 [Section new -name "foo"]
    set u1 [User new -created_at 123 -email "blblb@mail.com" -password foo -username john -moderates $s2]
    set p1 [Post new -title "foo" -section $s1 -author $u1 -created_at 123 -text "abcd fkj"]
    set p2 [Post new -title "title in s2" -section $s2 -author $u1 -created_at 222 -text "msg in s2"]

    puts "Flush the session..."

    ::tpersist::session done

    puts "Done."

}

puts "\nDump:"
puts [join [MyDB dump] \n]

puts "\nRetrieve objects..."

::tpersist::session new

set s1 [Section get 1]

puts "Session s1:"
puts "  id         : [$s1 id]"
puts "  posts      : [$s1 posts]"
puts "  name       : [$s1 name]"
puts "  moderators : [$s1 moderators]"

set p2 [Post get 2]

puts "Post p2:"
puts "  id         : [$s1 id]"
puts "  posts      : [$s1 posts]"
puts "  name       : [$s1 name]"
puts "  moderators : [$s1 moderators]"

::tpersist::session done





