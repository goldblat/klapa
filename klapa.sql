CREATE OR REPLACE FUNCTION lch.cluster_patterns(source_file_name text DEFAULT ''::text, tail_source_p real DEFAULT 0.1, source_table_name text DEFAULT ''::text, source_table_column_name text DEFAULT ''::text, words_range text DEFAULT '6,20'::text, words_delimiter text DEFAULT '[\s\[]+'::text, sample_p real DEFAULT 0.5, word_occurrences_threshold integer DEFAULT 50, pattern_occurrences_threshold integer DEFAULT 50)
 RETURNS TABLE(p double precision, pattern text, occurrences integer, num_of_words integer, sample text)
 LANGUAGE plpgsql
AS $function$

  DECLARE 
    total_rows_in_source INT;
  
  
BEGIN

  RAISE NOTICE 'START SCRIPT: %'  , timeofday()::timestamp; END IF;

  IF (source_file_name != '' AND source_table_name != '') OR (source_file_name = '' AND source_table_name = '') THEN 
     RAISE EXCEPTION 'Please provide only one source for clustering: source_file_name OR source_table_name';
  END IF;

  IF (source_table_name != '' AND source_table_column_name = '') THEN 
     RAISE EXCEPTION 'Please provide parameter column name (source_table_column_name) to cluster when specifying source_table_name';
  END IF;

  IF (SPLIT_PART(words_range,',',1)::INT > SPLIT_PART(words_range,',',2)::INT) THEN 
     RAISE EXCEPTION 'words_range parameter should be in form x,y where x<=y';
  END IF;

  IF (tail_source_p > 1 OR tail_source_p < 0 OR sample_p > 1 OR sample_p < 0) THEN 
     RAISE EXCEPTION 'tail_source_p OR tail_source_p values are out of range (0..1)';
  END IF;
 


  IF (source_table_name != '') THEN
     EXECUTE 'CREATE TEMPORARY VIEW source AS SELECT ' || source_table_column_name || ' AS string FROM ' || source_table_name;
  ELSE
     EXECUTE 'CREATE FOREIGN TABLE source(string TEXT) SERVER FILE_FDW_SERVER OPTIONS (FORMAT ''text'',FILENAME ''' || source_file_name || ''',ENCODING ''utf8'', DELIMITER E''\x01'');';
  END IF;

  SELECT COUNT(string) 
    FROM source
    INTO total_rows_in_source;

  RAISE NOTICE 'FINISHED count(*): %'  , timeofday()::timestamp;
  
  CREATE TEMPORARY TABLE source_sample ON COMMIT DROP AS
      SELECT string, 
             ROW_NUMBER() OVER () AS id
        FROM (SELECT  string,
                      ROW_NUMBER() OVER (ORDER BY string) AS original_id
              FROM  source
              ) AS ordered_source
       WHERE (original_id > total_rows_in_source * (1 - tail_source_p))
       ORDER BY RANDOM()
       LIMIT (total_rows_in_source * tail_source_p * sample_p);

 RAISE NOTICE 'FINISHED BUILDING source_sample: %'  , timeofday()::timestamp;
     
 IF (source_table_name != '') THEN
     DROP VIEW source;
  ELSE
     DROP FOREIGN TABLE source;
  END IF;  
  
  CREATE TEMPORARY TABLE explode_words_pivot ON COMMIT DROP AS
      WITH explode_words AS (SELECT id::INT,
                                    word,
                                    word_position::BIGINT
                               FROM source_sample t,
                                    regexp_split_to_table(t.string, words_delimiter)
                                    WITH ORDINALITY x(word, word_position))
      SELECT word_position,
             word,
             ARRAY_AGG(DISTINCT id) word_pos_in_strings
        FROM explode_words
       WHERE TRIM(word) != ''
             AND word_position BETWEEN SPLIT_PART(words_range,',',1)::INT 
             AND SPLIT_PART(words_range,',',2)::INT 
       GROUP BY word,
                word_position
       ORDER BY word_position,
                ARRAY_LENGTH(ARRAY_AGG(DISTINCT id), 1) DESC;    

  RAISE NOTICE 'FINISHED BUILDING explode_words_pivot: %'  , timeofday()::timestamp;
              
  CREATE TEMPORARY TABLE explode_words_pivot_sliced ON COMMIT DROP AS
      SELECT *
        FROM explode_words_pivot
       WHERE ARRAY_LENGTH(word_pos_in_strings, 1) >= word_occurrences_threshold;                                

  RAISE NOTICE 'FINISHED BUILDING explode_words_pivot_sliced: %'  , timeofday()::timestamp;
     
  DROP TABLE explode_words_pivot;
       /* Histogram of words occuring in strings:
          SELECT COUNT(*) number_of_words,                            
                 ARRAY_LENGTH(word_pos_in_strings, 1) occuring_in_strings                            
            FROM explode_words_pivot_sliced
           GROUP BY ARRAY_LENGTH(word_pos_in_strings, 1)
           ORDER BY ARRAY_LENGTH(word_pos_in_strings, 1) DESC
        */                                
  
  CREATE INDEX explode_words_pivot_sliced_word_position_gist
            ON explode_words_pivot_sliced
         USING GIST(word_pos_in_strings GIST__INTBIG_OPS, word_position);                                

  RAISE NOTICE 'FINISHED BUILDING index explode_words_pivot_sliced_word_position_gist: %'  , timeofday()::timestamp;


  CREATE TEMPORARY TABLE words_tree ON COMMIT DROP AS
      WITH RECURSIVE words_tree AS 
          (SELECT word_position,
                  word,
                  REPEAT('* ', (word_position - 1)::INT) || word AS tree,
                  word_position::TEXT AS pos_tree,
                  word_pos_in_strings,
                  1 AS depth,
                  ARRAY_LENGTH(word_pos_in_strings, 1) AS number_of_occurrences
             FROM explode_words_pivot_sliced
            WHERE array_length(word_pos_in_strings, 1) >= pattern_occurrences_threshold
            UNION
           SELECT child.word_position,
                  child.word,
                  parent.tree || ' ' || repeat('* ', (child.word_position - parent.word_position - 1)::int) || child.word,
                  parent.pos_tree || '.' || child.word_position::text,
                  parent.word_pos_in_strings & child.word_pos_in_strings,
                  parent.depth + 1,
                  array_length(parent.word_pos_in_strings & child.word_pos_in_strings, 1)
             FROM explode_words_pivot_sliced child
             JOIN words_tree parent
               ON parent.word_position < child.word_position
                  AND child.word_pos_in_strings && parent.word_pos_in_strings
            WHERE ARRAY_LENGTH(parent.word_pos_in_strings & child.word_pos_in_strings, 1) >= pattern_occurrences_threshold)
      SELECT words_tree.tree,
             words_tree.pos_tree,
             word_pos_in_strings,
             words_tree.number_of_occurrences,
             depth
        FROM words_tree;                                

  RAISE NOTICE 'FINISHED BUILDING words_tree: %'  , timeofday()::timestamp;

  RETURN QUERY
      SELECT words_tree_matches.number_of_occurrences / (total_rows_in_source * tail_source_p * sample_p) AS p,
             words_tree_matches.tree || COALESCE(CASE 
                                                   WHEN ARRAY_LENGTH(STRING_TO_ARRAY(words_tree_matches.tree, ' '), 1) < SPLIT_PART(words_range,',',2)::INT
                                                     THEN ' *?'
                                                 END, '') AS pattern,
             words_tree_matches.number_of_occurrences occurrences,
             words_tree_matches.depth AS num_of_words,
             source_sample.string::text AS sample    
        FROM (SELECT *,
                     ROW_NUMBER() OVER(PARTITION BY word_pos_in_strings ORDER BY depth DESC) AS best_match
              FROM words_tree) AS words_tree_matches
        LEFT JOIN source_sample
          ON words_tree_matches.word_pos_in_strings[1] = source_sample.id
       WHERE words_tree_matches.best_match = 1
       ORDER BY words_tree_matches.number_of_occurrences DESC,
             depth DESC;

  RAISE NOTICE 'FINISHED SCRIPT: %'  , timeofday()::timestamp;
           
           
END 

$function$
;
