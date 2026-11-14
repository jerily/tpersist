# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Apply a schema file twice and preserve existing data.
package require tpersist
namespace import ::tpersist::db_*

set schema [file join [file dirname [info script]] sql users.json]
set db [db_connect -database :memory: -autobegin 0]
try {
    db_apply_schema $db $schema
    db_execute $db [db_values [db_insert users] {email alice@example.com}]
    # Opt in to missing columns when applying a later revision of this file.
    db_apply_schema $db $schema -additive true
    puts [dict get [db_execute $db [db_select users]] rows]
} finally {
    db_disconnect $db
}
