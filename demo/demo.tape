# Records the README demo (demo/demo.mp4 and demo/demo.gif). Run from the repo root: vhs demo/demo.tape
Output demo/demo.gif
Output demo/demo.mp4
Require nvim

Set Shell bash
Set FontSize 18
Set Width 1000
Set Height 420
Set Padding 16
Set TypingSpeed 60ms
Set Theme "Builtin Dark"

Hide
Type "cp demo/flow.mmd /tmp/flow.mmd && cp demo/er.mmd /tmp/er.mmd && clear && nvim -n -u demo/init.lua /tmp/flow.mmd"
Enter
Sleep 1s
Show
Sleep 1s

# Put the steps in order.
Hide
Escape
Sleep 300ms
Type `:lua Step([[login --> \zsapply]], '<leader>mj  swap a step with the next one')`
Enter
Show
Sleep 1.2s
Type " mj"
Sleep 2s

# Insert a step between two nodes.
Hide
Escape
Sleep 300ms
Type `:lua Step([[browse --> \zsapply]], '<leader>mi  insert a step between two nodes')`
Enter
Show
Sleep 1.2s
Type " mi"
Sleep 500ms
Type "Upload CV"
Sleep 300ms
Enter
Sleep 2s

# Change a node's shape (6 = Circle).
Hide
Escape
Sleep 300ms
Type `:lua Step([[\<done(]], '<leader>ms  change a node shape')`
Enter
Show
Sleep 1.2s
Type " ms"
Sleep 1.2s
Type "6"
Sleep 300ms
Enter
Sleep 2s

# Remove a node; its neighbours are reconnected.
Hide
Escape
Sleep 300ms
Type `:lua Step([[--> \zslogin]], '<leader>md  remove a node and reconnect its neighbours')`
Enter
Show
Sleep 1.2s
Type " md"
Sleep 2s

# ER diagram: rename an entity everywhere (ORDER_LINE is left alone).
Hide
Type `:e /tmp/er.mmd`
Enter
Type `:lua Step([[CUSTOMER]], '<leader>mr  rename an entity everywhere it appears')`
Enter
Show
Sleep 1.5s
Type " mr"
Sleep 600ms
Ctrl+U
Type "ACCOUNT"
Sleep 300ms
Enter
Sleep 3s
