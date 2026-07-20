# A few more thought and problems about "mod ecosystems"

## "We need packages in the file names, because some files appears multiple times"

Well, so far it was only Manifest.transposed.tsv and Files.tsv. We already force
every file within a single package to have a unique name, except for Files.tsv
Basically, Files.tsv and Manifest.transposed.tsv are "meta-data" files,
unlike all the other files. The "unique" constraint is on the data files only.

But we still get the problem, when we get multiple packages together. Their meta-data
files are going to be duplicated, and it is legal for them to also have data-files with
the same name, and possibly also path.

## Merged Manifests

We already create a global schema file when we export. We should also create a global
Manifest.tsv file when we export. It would not be transposed, and it would contain
one row per package. We would have to somehow deal with the fact, that the Manifest
might not all represent the same code version. Also, we need to deal with the
"additional columns" (which are "rows" in the transposed format). We could, for example,
have one more column the in "merged" table, that is a map, where the key is the full
column header (name:type) and the value is the value in the original manifest.
The packages would be ordered in their "processing order". AFAIK, this order
can be influenced by the user.

## Merged Files List

We should also have a global Files list. The key column would be the "simple",
case insensitive exported file name, and the second column would be a list of packages
where that file is to be found. If, depending on the export options, we do not
export all the files, what do we do? Do we want/need to list some "hashcode"
for each file, to detect corruption?

## Duplicated utility packages

Some, usually small, utility packages, are often very popular. If packages
creators "embed" those in their own packages, they might easily end up
multiple times in a multi-package setup. Do we need to deal with this
any particular way? With "dependency" packages, it's different. We only
load each dependency once, and we have to find a version that is compatible
with all the packages that requires them.
