package require tpersist::oo
namespace import ::tpersist::db_*

set database [::tpersist::oo::Database new -database :memory:]
try {
    $database create_table [db_define_table users {
        id {type integer primary_key 1 auto_increment 1}
        name {type text}
        age {type integer}
    }]
    set insert [$database insert users]
    $database transaction {
        foreach {name age} {Alice 30 Bob 17 Carol 42} {
            $insert values [dict create name $name age $age]
            $insert execute
        }
    }

    # set everyone [$database select users -columns {name age}]
    set everyone [$database select users -expr {name, age}]
    set adults [$everyone fork]
    # $adults where [db_ge [db_col age] [db_value 18 -type integer]]
    $adults where -expr {age >= 18}
    # $adults order_by [db_desc [db_col age]]
    $adults order_by -expr {age DESC}
    $adults limit 10
    puts "Adults: [$adults all]"
    puts "Everyone: [$everyone all]"

    # Interoperate with procedural code using the same statement dictionary.
    puts "SQL: [dict get [db_compile [$adults statement]] sql]"
} finally {
    # Also destroys its queries and disconnects the TDBC connection.
    $database destroy
}
