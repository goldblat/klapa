# Klapa
Text patterns clustering in PostgreSQL

## What is Klapa?
**Klapa** (pronounced kla·pa /ˈkläpä/) is a relatively fast and efficient genuine algorithm to find patterns in a dataset of strings. 

**Klapa**  allows clustering patterns from DB tables or the file-system and relies on PostgreSQL(>=11) to tackle performance issues that are common in  clustering combinatorics.

## Motivation
The ability the detect reoccurring textual patterns is useful in fields that require data investigation such as:
- Log files analysis (anomalies detection, health monitoring)
- Debugging trace files
- Natural language processing (NLP)

## Demo
Assume you have the following strings and want to find the most common patterns:

    - the black fox jumped over the bench
    - the red fox walked over the river
    - the yellow fox skipped the line
    - one yellow fox saw a bird
    - the yellow dog flipped over the pool
    - the black cow flipped over the pool
    - the black cat flipped over the pool
    - the yellow dog flipped over the pool  

**Klapa** clusters these strings into the following output (top 5 results):

| p     | pattern                                 | occurrences | # words | sample                               |
|-------|-----------------------------------------|-------------|--------|--------------------------------------|
| 0.875 | the *?                                  | 7           | 1      | the black cat flipped over the pool  |
| 0.75  | the * * * over the *?                   | 6           | 3      | the black cat flipped over the pool  |
| 0.5   | the * * flipped over the pool *?        | 4           | 5      | the black cat flipped over the pool  |
| 0.5   | * * fox *?                              | 4           | 1      | one yellow fox saw a bird            |
| 0.5   | * yellow *?                             | 4           | 1      | one yellow fox saw a bird            |

So it can be easily seen that for instance, the pattern `the * * * over the *?` appears in 75% of the strings (each asterisk represents a single word in its place, similar to \S in regex).


## Installation
1. The best way to install Klapa is to import the `klapa.sql` file into the chosen database.
2.  Enable required extensions:
`postgres=# CREATE EXTENSION intarray;`
`postgres=# CREATE EXTENSION btree_gist;`
3. If you want to analyze text files, enable the foreign data wrapper extension and create a "server":
`postgres=# CREATE EXTENSION file_fdw;`
`postgres=# CREATE SERVER file_fdw_server FOREIGN DATA WRAPPER file_fdw;`

From there, you can start interacting with the `cluster_patterns` function.

## Usage

### Quick Start

Cluster a text column in the database using default parameters:
```sql
postgres=# SELECT * FROM cluster_patterns(source_table_name => 'email.messages', source_table_column_name => 'subject')
 ```

Cluster a text file:
```sql
postgres=# SELECT * FROM cluster_patterns(source_file_name => '/var/log/postgresql/postgresql.log')
```

### Parameters

- **source_file_name** - Full path to text file. Postgres user on OS should have read access to it. Either this field or `source_table_name` are mandatory per your data source type.
- **source_table_name** - Table name that hold the column to cluster. Note that if this table is not in the same schema where the `cluster_patterns` function is installed you should provide the full path to schema and table in form of `'schema.tablename'`.
- **source_table_column_name** - Column name that holds the strings to cluster. Mandatory when providing `source_table_name` parameter.
- **tail_source_p** - Process only the last `x%` rows in the data source. Value of 1 will process the whole data source, while value of 0.1 will process only the last 10% of the rows. This is mostly useful when there's a need to inspect more recent data such as in with log files. If the data source is file, this parameter trims the last lines of the file, while if the data source is a database table, the function tails the last rows returned by the database in `select * from tablename` and might not reflect insertion, sequential or timestamp order. (default 0.1)
- **words_range** - Define the range of words in the sentence the algorithm will take into account - start and last word positions, separated by a comma. Useful in log files when the strings are starting with a unique pattern (such as timestamp, server name or IP address) or when the lines don't hold relevant text after a certain position. Narrower range will reduce the possible words combination and will result in faster performance. (default '6,20')
- **words_delimiter** - Regular expression that when matched is used to split sentences into words. Defaults characters are space and open square-brackets. (default '[\s\[]+')
- **sample_p** - Percent of rows to analyze from the data source after performing the tail step. The rows are randomly chosen. (default 0.5).
- **word_occurrences_threshold** - Minimum number of occurrences that a word should appear in the data set to be considered into one of the patterns. Lowering this number increases the possible combinations in the recursive patterns loop (preparation of words_tree table) and negatively impacts performance.  (default 50)
- **pattern_occurrences_threshold** - Minimum number of occurrences that a pattern should appear in the data source to be included in the query result. Changing this number has a low impact on performance. (default 50)

#### Example

Find patterns in the first 5 words in the subjects column in the messages table. Limit calculations to the last 25% messages, and sample randomly only 50% of them.
```sql
postgres=# SELECT * FROM cluster_patterns(source_file_name => 'email.messages',
                               source_table_column_name =>'subject',
                               words_range => '1,5',
                               tail_source_p=>0.25,
                               sample_p=>0.5)
```

### Caveats
 1. Due to Postgres `Copy` function encoding limitations, some files might return `SQL Error [22P04]: ERROR: literal carriage return found in data` error. These files need further preparation before processing to remove special Unicode characters and carriage returns. Using the terminal:
 `sed 's:\\:\\\\:g; s:\r:\\r:g' /var/log/postgresql/postgresql.log /var/log/postgresql/altered.log`

## Algorithm Features

### Scaling
Klapa was benchmarked against multiple scenarios to optimize the execution plans and to improve performance and memory footprints. This was done by extending some PostgreSQL features to the limit and requirement to enable some native extensions.
Yet, for very large datasets the process of exploding the words dictionary and aggregating the patterns tend to stretch resources and grow big.
The following tips can help to reduce process times, CPU and memory consumption:
- If the number of strings in the data source is high, lower `sample_p` *(default=0.5)* parameter to reduce the random sample size.
- For sources where recent data is more relevant (such as in log files) use the `tail_source_p` *(default=0.1)* parameter to analyze only the last x% of the data. 
- For strings with repeating irrelevant parts (such as log files where the first words represent timestamp, machine name etc), change the `words_range` *(default=6,20)*.
- Based on your dataset size try altering the `word_occurrences_threshold` *(default=50)* and `pattern_occurrences_threshold` *(default=50)* to pick only the most repetitive words.
- 
### Principles

- Code Readability.  SQL formatting based on style guide from [sqlstyle.guide](https://www.sqlstyle.guide/)
- Ease of Use. This implementation  is distributed as a single PL/pgSQL function, which means it can be installed and used easily.
- Using DB Goodies. Postgres comes with lots of features that can stretch performance to max. Some of them are tricky and needs deep knowledge of the DB engine.
- Built for Production. Not compromising for the sake of POC.
- Leave No Trace. All runtime objects are temporary and lives only during through the query session.
 
## Future Work

### Todo

1. Add ignore_characters[array], stop_words[array] and underscore_words[bool] to slice the words dictionary.
2. Consider **hyperloglog** to extend calculation from sample to whole data source.
3. Utilize Postgres' multi-core parallelism to speed up the recursive query that builds the `words_tree` combinations table. This is the heaviest query in the algorithm. PG12 doesn't support parallel gathering of recursive CTE (I could not achieve parallel execution even by dividing the parent node of the recursive loop into multiple UNION ALL queries).
4. ~~Change aggregated columns words_tree fields (tree, pos_tree) to be arrays of words IDs and word positions instead of concatenated strings.~~ (proved to increase memory consumption and the perf improvement is neglected even for huge datasets)
5. ~~Separate `explode_words_pivot_sliced_word_position_gist` to 2 indexes~~ (Postgres plan optimizer prefers such indexes over the current multi-column index yet they provide slower execution time)

### Bugs & Issues
I'm open to any kind of contributions and happy to discuss, review and merge pull requests.
I also invite any questions, comments, bug reports, patches directly to my mail address.


## Inspiration
The **Klapa** algorithm is genuine, yet the idea of text clustering into patterns was inspired from the following publications:
- [LogMine](https://dl.acm.org/citation.cfm?id=2983323.2983358): Fast Pattern Recognition for Log Analytics  for the idea of coarse grained clustering and the idea of type deduction to simplify logs.
-   [nestordemeure/textPatterns]([https://github.com/nestordemeure/textPatterns/](https://github.com/nestordemeure/textPatterns/)) - Hierarchical clustering of lines of text.
- Kusto reduce operator [(link)](https://docs.microsoft.com/en-us/azure/data-explorer/kusto/query/reduceoperator)
- A Data Clustering Algorithm for Mining Patterns From Event Logs by Risto Vaarandi [(link)](https://ristov.github.io/publications/slct-ipom03-web.pdf)

## About

### Author
The project was founded in 2020 by Yoni G ([email](goldblat-remove.this-@gmail.com) / [LinkedIn](https://www.linkedin.com/in/goldblat/))

**💸 Do you like my work?** I am a Senior Backend & Data Engineer open to offers and opportunities

### Why the name?
The word klapa translates from Croatian as ["a group of friends"](https://en.wikipedia.org/wiki/Klapa) which resembles the idea of patterns clustering.
In addition it consists of 2 syllables, each pronounced as the stems of "**clu**stering **pa**tterns".


## License
**Klapa** is distributed using MIT license, which means you can use and modify it however you want. However, if you make an enhancement for it, if possible, please send a pull request.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.