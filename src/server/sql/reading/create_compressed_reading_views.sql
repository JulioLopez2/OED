/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */


/*
Rounds a timestamp up to the next interval
 */
CREATE OR REPLACE FUNCTION date_trunc_up(interval_precision TEXT, ts TIMESTAMP)
	RETURNS TIMESTAMP LANGUAGE SQL
IMMUTABLE
AS $$
SELECT CASE
			 WHEN ts = date_trunc(interval_precision, ts) THEN ts
			 ELSE date_trunc(interval_precision, ts + ('1 ' || interval_precision)::INTERVAL)
			 END
$$;


CREATE OR REPLACE FUNCTION shrink_tsrange_to_real_readings(tsrange_to_shrink TSRANGE)
	RETURNS TSRANGE
AS $$
DECLARE
	readings_max_tsrange TSRANGE;
BEGIN
	SELECT tsrange(min(start_timestamp), max(end_timestamp)) INTO readings_max_tsrange
	FROM readings;
	RETURN tsrange_to_shrink * readings_max_tsrange;
END;
$$ LANGUAGE 'plpgsql';

/*
	The following views are all generated by generateCompressedReadingViews.js in this folder.
	This is necessary because they can't be wrapped in a function (otherwise predicates would not be pushed down).
*/

/*
The query shared by all of these views gets slow when one of two things happen:
	1) It has to scan a large percentage of the readings table
	2) It has to generate a large number of rows (by compressing to a small interval)
We pick the best of both worlds by only materializing the large duration tables (day+).
These produce far fewer rows than the non-materialized tables, making them cheap to store,
but they benefit from materialization because they require a scan of a large percentage of
the readings table (to aggregate data over a large time range).

The small tables, on the other hand, are only queried for small time ranges that produce a few hundred data points.
This is the best-case scenario for these queries, and leads to quick execution times if the table is properly clustered.
 */

/*
 The minutely_readings view below is no longer used. Instead of reading from this view,
 we choose to reading directly from the raw readings table.

CREATE OR REPLACE VIEW
minutely_readings
	AS SELECT
				r.meter_id AS meter_id,
				-- This gives the weighted average of the reading rates, defined as
				-- sum(reading_rate * overlap_duration) / sum(overlap_duration)
				(sum(
						 (r.reading / (extract(EPOCH FROM (r.end_timestamp - r.start_timestamp)) / 3600)) -- Reading rate in kw
						 *
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 minute'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 ) / sum(
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 minute'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 )) AS reading_rate,
				tsrange(gen.interval_start, gen.interval_start + '1 minute'::INTERVAL, '()') AS time_interval
			FROM readings r
				CROSS JOIN LATERAL generate_series(
						date_trunc('minute', r.start_timestamp),
						-- Subtract 1 interval width because generate_series is end-inclusive
						date_trunc_up('minute', r.end_timestamp) - '1 minute'::INTERVAL,
						'1 minute'::INTERVAL
				) gen(interval_start)
			GROUP BY r.meter_id, gen.interval_start;
*/

CREATE MATERIALIZED VIEW IF NOT EXISTS
hourly_readings
	AS SELECT
				r.meter_id AS meter_id,
				-- This gives the weighted average of the reading rates, defined as
				-- sum(reading_rate * overlap_duration) / sum(overlap_duration)
				(sum(
						 (r.reading / (extract(EPOCH FROM (r.end_timestamp - r.start_timestamp)) / 3600)) -- Reading rate in kw
						 *
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 hour'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 ) / sum(
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 hour'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 )) AS reading_rate,
				tsrange(gen.interval_start, gen.interval_start + '1 hour'::INTERVAL, '()') AS time_interval
			FROM readings r
				CROSS JOIN LATERAL generate_series(
						date_trunc('hour', r.start_timestamp),
						-- Subtract 1 interval width because generate_series is end-inclusive
						date_trunc_up('hour', r.end_timestamp) - '1 hour'::INTERVAL,
						'1 hour'::INTERVAL
				) gen(interval_start)
			GROUP BY r.meter_id, gen.interval_start;

CREATE MATERIALIZED VIEW IF NOT EXISTS
daily_readings
	AS SELECT
				r.meter_id AS meter_id,
				-- This gives the weighted average of the reading rates, defined as
				-- sum(reading_rate * overlap_duration) / sum(overlap_duration)
				(sum(
						 (r.reading / (extract(EPOCH FROM (r.end_timestamp - r.start_timestamp)) / 3600)) -- Reading rate in kw
						 *
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 day'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 ) / sum(
						 extract(EPOCH FROM -- The number of seconds that the reading shares with the interval
										 least(r.end_timestamp, gen.interval_start + '1 day'::INTERVAL)
										 -
										 greatest(r.start_timestamp, gen.interval_start)
						 )
				 )) AS reading_rate,
				tsrange(gen.interval_start, gen.interval_start + '1 day'::INTERVAL, '()') AS time_interval
			FROM readings r
				CROSS JOIN LATERAL generate_series(
						date_trunc('day', r.start_timestamp),
						-- Subtract 1 interval width because generate_series is end-inclusive
						date_trunc_up('day', r.end_timestamp) - '1 day'::INTERVAL,
						'1 day'::INTERVAL
				) gen(interval_start)
			GROUP BY r.meter_id, gen.interval_start
		 -- The order by ensures that the materialized view will be clustered in this way.
			ORDER BY gen.interval_start, r.meter_id;

CREATE EXTENSION IF NOT EXISTS btree_gist;
-- We need a gist index to support the @> operation.
CREATE INDEX if not exists idx_daily_readings ON daily_readings USING GIST(time_interval, meter_id);


/*
The following function determines the correct duration view to query from, and returns compressed data from it.
 */
CREATE OR REPLACE FUNCTION compressed_readings_2(meter_ids INTEGER[], start_stamp TIMESTAMP, end_stamp TIMESTAMP)
	RETURNS TABLE(meter_id INTEGER, reading_rate FLOAT, start_timestamp TIMESTAMP, end_timestamp TIMESTAMP)
AS $$
DECLARE
	requested_interval INTERVAL;
	requested_range TSRANGE;

	/*
		The minimum day and hourly points are determined so that data is read from the daily view when the
		requested interval is at least two months, from the hourly view when between two months and at least two weeks,
		and directly from the raw readings table when under two weeks.

		+----------------------+--------------------
		| Space considerations |
		+----------------------+
		Each row returned by this function contains 1 INT (meter_id), 2 TIMESTAMPs (start/end stimestamp), and
		1 FLOAT (reading_rate). According to PostgreSQL documentation, the storage size of INT is 4 bytes,
		TIMESTAMP is 8 bytes, and FLOAT is 8 bytes, and so each row totals to 28 bytes of data.

		For example, if the requested range is one year, this algorithm will read from the materialized daily view
		and return 0.01 megabytes of data.
		
		From the hourly view, the number rows that can be read ranges from 360 (the minimum) to 60 * 24 = 1440
		points. Hence, the amount of data read from the hourly view ranges from 0.010 to 0.040 megabytes
		per meter. 
		
		From the readings table, the number of rows returned depends on the raw reading granularity.
		The most common reading granularity for electric meters is 15-minutes, which means the meter
		stores data for every 15-minute interval.

		The transition from hourly to raw readings occurs when the number of hourly points is 359 or less which is
		less than 15 days or roughly two weeks.

		If the granularity is 15-minutes, then the maximum amount of raw points is 359 * 4 = 1436, which translates
		to 0.040 megabytes per meter.
		If instead the raw readings granularity is 1-minute, then the maximum amount of raw points is 359 * 60 = 21540,
		which translates to 0.60 megabytes per meter. 
		

		+------+-------------------
		| TODO |
		+------+
		- Note that the above documentation does not account for the increase in data when packaged in JSON format.
		- This function is complicated by the fact that groups can contain meters with different levels of granularity.
		We address this now by having sites pick a site-level reading frequency. (Not done)
		- When resource generalization is implemented in OED, this function will need to be done in a 
		meter-by-meter basis, since different resource meters will have different levels of granularity.
	*/
	minimum_day_points INTEGER = 61;
	minimum_hour_points INTEGER = 360;
BEGIN

	requested_range := shrink_tsrange_to_real_readings(tsrange(start_stamp, end_stamp, '[]'));
	requested_interval := upper(requested_range) - lower(requested_range);

	IF extract(DAY FROM requested_interval) >= minimum_day_points THEN
		RETURN QUERY
			SELECT
				daily.meter_id AS meter_id,
				daily.reading_rate,
				lower(daily.time_interval) AS start_timestamp,
				upper(daily.time_interval) AS end_timestamp
			FROM daily_readings daily
			INNER JOIN unnest(meter_ids) meters(id) ON daily.meter_id = meters.id
			WHERE requested_range @> time_interval;
	-- There's no quick way to get the number of hours in an interval. extract(HOURS FROM '1 day, 3 hours') gives 3.
	ELSIF extract(EPOCH FROM requested_interval)/3600 >= minimum_hour_points THEN
		RETURN QUERY
			SELECT hourly.meter_id AS meter_id,
				hourly.reading_rate,
				lower(hourly.time_interval) AS start_timestamp,
				upper(hourly.time_interval) AS end_timestamp
			FROM hourly_readings hourly
			INNER JOIN unnest(meter_ids) meters(id) ON hourly.meter_id = meters.id
		WHERE requested_range @> time_interval;
	 ELSE
	-- Default to RAW data
 		RETURN QUERY
			SELECT r.meter_id as meter_id,
				(r.reading / (extract(EPOCH FROM (r.end_timestamp - r.start_timestamp)) / 3600)) as reading_rate, -- Reading rate in kw
 				r.start_timestamp,
 				r.end_timestamp
 			FROM readings r
 			INNER JOIN unnest(meter_ids) meters(id) ON r.meter_id = meters.id
 		WHERE lower(requested_range) <= r.start_timestamp AND r.end_timestamp <= upper(requested_range);
	 END IF;
END;
$$ LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION compressed_group_readings_2(group_ids INTEGER[], start_stamp TIMESTAMP, end_stamp TIMESTAMP)
	RETURNS TABLE(group_id INTEGER, reading_rate FLOAT, start_timestamp TIMESTAMP, end_timestamp TIMESTAMP)
AS $$
	DECLARE
		meter_ids INTEGER[];
	BEGIN
		-- First get all the meter ids that will be included in one or more groups being queried
		SELECT array_agg(gdm.meter_id) INTO meter_ids
		FROM groups_deep_meters gdm
		INNER JOIN unnest(group_ids) gids(id) ON gdm.group_id = gids.id;

		RETURN QUERY
			SELECT
				gdm.group_id AS group_id,
				SUM(compressed.reading_rate) AS reading_rate,
				compressed.start_timestamp,
				compressed.end_timestamp
			FROM compressed_readings_2(meter_ids, start_stamp, end_stamp) compressed
			INNER JOIN groups_deep_meters gdm ON compressed.meter_id = gdm.meter_id
			INNER JOIN unnest(group_ids) gids(id) on gdm.group_id = gids.id
			GROUP BY gdm.group_id, compressed.start_timestamp, compressed.end_timestamp;
	END;
$$ LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION compressed_barchart_readings_2(
	meter_ids INTEGER[],
	bar_width_days INTEGER,
	start_stamp TIMESTAMP,
	end_stamp TIMESTAMP
)
	RETURNS TABLE(meter_id INTEGER, reading FLOAT, start_timestamp TIMESTAMP, end_timestamp TIMESTAMP)
AS $$
DECLARE
	bar_width INTERVAL;
	real_tsrange TSRANGE;
	real_start_stamp TIMESTAMP;
	real_end_stamp TIMESTAMP;
BEGIN
	bar_width := INTERVAL '1 day' * bar_width_days;
	real_tsrange := shrink_tsrange_to_real_readings(tsrange(date_trunc_up('day', start_stamp), date_trunc('day', end_stamp)));
	real_start_stamp := date_trunc_up('day', lower(real_tsrange));
	real_end_stamp := date_trunc('day', upper(real_tsrange));
	RETURN QUERY
		SELECT dr.meter_id AS meter_id,
			--  dr.reading_rate is the weighted average reading rate over the day, in kW. To convert it to kW * h,
			-- we do reading_rate (kw) * time (1 day) * (24 hr / 1 day) to get kW H.
			SUM(dr.reading_rate * 24) AS reading,
			bars.interval_start AS start_timestamp,
			bars.interval_start + bar_width AS end_timestamp
	FROM daily_readings dr
	INNER JOIN generate_series(real_start_stamp, real_end_stamp, bar_width) bars(interval_start)
			ON tsrange(bars.interval_start, bars.interval_start + bar_width, '[]') @> dr.time_interval
	INNER JOIN unnest(meter_ids) meters(id) ON dr.meter_id = meters.id
	GROUP BY dr.meter_id, bars.interval_start;

END;
$$ LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION compressed_barchart_group_readings_2(
	group_ids INTEGER[],
	bar_width_days INTEGER,
	start_stamp TIMESTAMP,
	end_stamp TIMESTAMP
)
	RETURNS TABLE(group_id INTEGER, reading FLOAT, start_timestamp TIMESTAMP, end_timestamp TIMESTAMP)
AS $$
DECLARE
	bar_width INTERVAL;
	real_tsrange TSRANGE;
	real_start_stamp TIMESTAMP;
	real_end_stamp TIMESTAMP;
BEGIN
	bar_width := INTERVAL '1 day' * bar_width_days;
	real_tsrange := shrink_tsrange_to_real_readings(tsrange(date_trunc_up('day', start_stamp), date_trunc('day', end_stamp)));
	real_start_stamp := date_trunc_up('day', lower(real_tsrange));
	real_end_stamp := date_trunc('day', upper(real_tsrange));
	RETURN QUERY
	SELECT gdm.group_id AS group_id,
				 SUM(dr.reading_rate * 24) AS reading, -- 24 hours in a day
				 bars.interval_start AS start_timestamp,
				 bars.interval_start + bar_width AS end_timestamp
	FROM daily_readings dr
		INNER JOIN generate_series(real_start_stamp, real_end_stamp, bar_width) bars(interval_start)
			ON tsrange(bars.interval_start, bars.interval_start + bar_width, '[]') @> dr.time_interval
		INNER JOIN groups_deep_meters gdm ON dr.meter_id = gdm.meter_id
		INNER JOIN unnest(group_ids) groups(id) ON gdm.group_id = groups.id
	GROUP BY gdm.group_id, bars.interval_start;
END;
$$ LANGUAGE 'plpgsql';
