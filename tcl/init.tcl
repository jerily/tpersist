# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

set dir [file dirname [info script]]

source [file join $dir entity.tcl]
source [file join $dir db.tcl]
source [file join $dir db_sqlite3.tcl]
source [file join $dir session.tcl]

package provide tpersist 1.0.0
