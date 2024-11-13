# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require tdbc
package require tdbc::sqlite3

package require tpersist

#puts "Create DB..."

set db_file "example1.sqlite3"
# set db_file ":memory:"

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
    Required   name       string -unique 1
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
    set s2 [Section new -name "foo1"]
    set s3 [Section new -name "baz"]
    set s2 [Section new -name "foo2"]
    set u1 [User new -created_at 123 -email "blblb@mail.com" -password foo -username john -moderates [list $s2 $s3]]
    set p1 [Post new -title "foo" -section $s1 -author $u1 -created_at 123 -text "abcd fkj"]
    set p2 [Post new -title "title in post2" -section $s2 -author $u1 -created_at 222 -text "msg in post2"]
    set p3 [Post new -title "title in post3" -section $s1 -author $u1 -created_at 222 -text "msg in post3"]

    set m1 [Message new -text "message N1" -author $u1 -created_at 123]

    puts "Flush the session..."

    ::tpersist::session done

    puts "Done."

}

puts "\nDump:"
puts [join [MyDB dump] \n]

puts "\nRetrieve objects...\n"
::tpersist::session new

puts "\nRetrieve Session #1...\n"
set s1 [Section get 1]

puts "Session s1: $s1"
puts "  id         : [$s1 id]"
puts "  posts      : [$s1 posts]"
puts "  name       : [$s1 name]"
puts "  moderators : [$s1 moderators]"

puts "\nRetrieve Post #2..."
set p2 [Post get 2]

puts "Post p2: $p2"
puts "  id           : [$p2 id]"
puts "  title        : [$p2 title]"
puts "  section      : [$p2 section]"
puts "    id         : [[$p2 section] id]"
puts "    posts      : [[$p2 section] posts]"
puts "    name       : [[$p2 section] name]"
puts "    moderators : [[$p2 section] moderators]"
puts "  author       : [$p2 author]"
puts "    id         : [[$p2 author] id]"
puts "    created_at : [[$p2 author] created_at]"
puts "    email      : [[$p2 author] email]"
puts "    password   : [[$p2 author] password]"
puts "    username   : [[$p2 author] username]"
puts "    votes      : [[$p2 author] votes]"
puts "    viewed     : [[$p2 author] viewed]"
puts "    messages   : [[$p2 author] messages]"
puts "    moderates  : [[$p2 author] moderates]"
puts "  created_at   : [$p2 created_at]"
puts "  text:        : [$p2 text]"

puts "\nRetrieve Post #2 (again)..."
set p22 [Post get 2]
puts "Post p2 (again): $p22"

# Update user

set u1 [User get 1]
puts "User u1: $u1"
puts "  username: [$u1 username]"
puts "  password: [$u1 password]"

if { [$u1 username] eq "john" } {
    $u1 username "john doe"
    $u1 password "mypass1"
} else {
    $u1 username "john"
    $u1 password "mypass2"
}

puts "\nClose the session..."

::tpersist::session done

puts "\nRetrieve Session #2...\n"
::tpersist::session new

# Check to see how the user is updated

set sections [Section select]
puts "Sections: $sections"

set u1 [User get 1]
puts "User u1: $u1"
puts "  username: [$u1 username]"
puts "  password: [$u1 password]"

puts "\nClose the session..."

::tpersist::session done

puts "\nNew Session #3...\n"
::tpersist::session new

# Set values via relationships

set messages [Message select]
puts "Messages: $messages"
set m1 [lindex $messages 0]
puts "Message m1: $m1"
puts "  votes: [$m1 votes]"
set u1 [User get 1]
puts "User u1: $u1"
puts "  votes: [$u1 votes]"

set v1 [Vote new -user $u1 -message $m1 -value 1 -created_at 123]

puts "\nClose the session..."

::tpersist::session done

puts "\nNew Session #4...\n"
::tpersist::session new

# Check values via relationships

set messages [Message select]
puts "Messages: $messages"
set m1 [lindex $messages 0]
puts "Message m1: $m1"
puts "  votes: [$m1 votes]"
set u1 [User get 1]
puts "User u1: $u1"
puts "  votes: [$u1 votes]"

puts "\nClose the session..."

::tpersist::session done

puts "\nNew Session #5...\n"
::tpersist::session new

# Here we will remove objects/rows from database.
# In this session, we will create 2 new section objects named "section for removal"
# and "section for removal alt" which we will delete in subsequent sessions.
# However, let's not create a new section if we already have a section with that name.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

foreach name [list "section for removal" "section for removal alt"] {
    if { ![dict exists $section_dict $name] } {
        puts "Add new section: '$name'"
        Section new -name $name
    } else {
        puts "Use existing section: '$name'"
    }
}

::tpersist::session done

puts "\nNew Session #6...\n"
::tpersist::session new

# In this session we will add a moderator to the section

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

if { $u1 ni [$sX moderators] } {

    puts "Add a moderator to the section"
    $sX moderators $u1 -append

    puts "Section: $sX ([$sX name])"
    puts "   moderators: [$sX moderators]"

    set u1 [User get 1]
    puts "User: $u1 ([$u1 username])"
    puts "   moderates: [$u1 moderates]"

} else {
    puts "The user is already a moderator of the section"
}

::tpersist::session done

puts "\nNew Session #7...\n"
::tpersist::session new

# In this session we will check if the new moderator is correctly added to the section.
# After that, we will remove the new moderator from the section.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

puts "Remove the moderator from the section"
$sX moderators $u1 -remove

puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #8...\n"
::tpersist::session new

# In this session we will check if the new moderator is correctly removed from the section.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #9...\n"
::tpersist::session new

# In this session we will add a section to the user

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal alt"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

if { $sX ni [$u1 moderates] } {

    puts "Add a section to the user"
    $u1 moderates $sX -append

    puts "Section: $sX ([$sX name])"
    puts "   moderators: [$sX moderators]"

    set u1 [User get 1]
    puts "User: $u1 ([$u1 username])"
    puts "   moderates: [$u1 moderates]"

} else {
    puts "The section is already added to the user"
}

::tpersist::session done

puts "\nNew Session #10...\n"
::tpersist::session new

# In this session we will check if the section is correctly added to the user.
# After that, we will remove the new section from the user.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal alt"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

puts "Remove the section from the user"
$u1 moderates $sX -remove

puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #11...\n"
::tpersist::session new

# In this session we will check if the new section is correctly removed from the user.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX [dict get $section_dict "section for removal alt"]
puts "Section: $sX ([$sX name])"
puts "   moderators: [$sX moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #12...\n"
::tpersist::session new

# In this session we link 2 section with 1 user

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX1 [dict get $section_dict "section for removal"]
puts "Section: $sX1 ([$sX1 name])"
puts "   moderators: [$sX1 moderators]"
set sX2 [dict get $section_dict "section for removal alt"]
puts "Section: $sX2 ([$sX2 name])"
puts "   moderators: [$sX2 moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

puts "Add 2 sections to the user"
$u1 moderates $sX1 -append
$u1 moderates $sX2 -append

puts "Section: $sX1 ([$sX1 name])"
puts "   moderators: [$sX1 moderators]"
puts "Section: $sX2 ([$sX2 name])"
puts "   moderators: [$sX2 moderators]"
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #13...\n"
::tpersist::session new

# In this session we check that 2 section are linked with the user.
# After that, we delete these 2 sections from database.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set sX1 [dict get $section_dict "section for removal"]
puts "Section: $sX1 ([$sX1 name])"
puts "   moderators: [$sX1 moderators]"
set sX2 [dict get $section_dict "section for removal alt"]
puts "Section: $sX2 ([$sX2 name])"
puts "   moderators: [$sX2 moderators]"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

puts "Destroy 2 sections"
$sX1 destroy
$sX2 destroy

puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #14...\n"
::tpersist::session new

# In this session we check that 2 section are deleted.

set section_objs [Section select]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

set u1 [User get 1]
puts "User: $u1 ([$u1 username])"
puts "   moderates: [$u1 moderates]"

::tpersist::session done

puts "\nNew Session #15...\n"
::tpersist::session new

# In this session we check object selection

set section_objs [Section select {name LIKE :pattern} [dict create pattern "foo%"]]
set section_dict [join [lmap s $section_objs { list [$s name] $s }]]
puts "Sections: $section_dict"

::tpersist::session done

puts "\nNew Session #16...\n"
::tpersist::session new

# In this session we will try to add a section with a duplicate name

set sX [Section new -name "bar"]

::tpersist::session done
