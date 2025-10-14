(lang dune 3.7)
(name awkcc)

(generate_opam_files true)

(source (github Chubek/awkcc))
(license MIT)
(authors "Chubak Bidpaa")
(maintainers "chubakbidpaa@riseup.net")

(package
 (name awkcc)
 (synopsis "An optimizing AWK to C compiler")
 (description "Awk2C compiles AWK programs to optimized C code with SSA-based transformations")
 (depends
  (ocaml (>= 4.14.0))
  (dune (>= 3.7))
  (menhir (>= 20230608))
  (ocamlgraph (>= 2.1.0))
  (alcotest :with-test)
  (odoc :with-doc)))

(using menhir 2.1)
