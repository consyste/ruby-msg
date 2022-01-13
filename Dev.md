# Developer use of ruby-msg

Install prerequisites from `Gemfile.lock` by:

```sh
bundle install
```

Display tasks.

```sh
rake -T
```

Run unit tests.

```sh
rake test
```

Docs.

```bat
gem install yard
yardoc --no-private -m markdown -M redcarpet -o docs\doc -r Home.md
```

Build `build/ruby-msg-nx-0.3.0`

```bat
rake gem
```
