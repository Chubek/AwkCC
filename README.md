# AwkCC: the Optimizing Awk Compiler

This is the home to AwkCC, an optimizing Awk compiler, which uses C as its target. AwkCC also yields a runtime library.

This is not a 'naive' source-to-source translator. Attempts have been made to create an Awk to C compiler, chiefly, AwkA, an old, ancient project. But AwkCC is not just a 'transpiler', it attempts to optimize the code by analyzing its flow of control and data, call graph, and it could optionally compile the EREs into switch statements, similar to that of Re2C.

It's still at a very young stage. If you are interested in seeing this project grow, start/watch the repository.
