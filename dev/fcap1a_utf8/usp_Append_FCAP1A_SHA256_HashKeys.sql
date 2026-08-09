USE [CDIO_MeditechDB];
GO

IF OBJECT_ID('dbo.usp_Append_FCAP1A_SHA256_HashKeys', 'P') IS NULL
BEGIN
    EXEC('CREATE PROCEDURE dbo.usp_Append_FCAP1A_SHA256_HashKeys AS BEGIN SET NOCOUNT ON; END');
END;
GO

ALTER PROCEDURE dbo.usp_Append_FCAP1A_SHA256_HashKeys
    @BatchSize INT = 50000,
    @RecomputeExisting BIT = 1,
    @IncludeClinicalNotes BIT = 0,
    @ContinueOnError BIT = 0,
    @FailOnDuplicateHash BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE
        @OverallRunStart DATETIME2(3) = SYSDATETIME(),
        @OverallRunEnd DATETIME2(3),
        @CurrentRunStart DATETIME2(3),
        @CurrentRunEnd DATETIME2(3),
        @DurationSeconds INT,
        @SchemaName SYSNAME,
        @TableName SYSNAME,
        @FullTableName NVARCHAR(600),
        @HashPrefix NVARCHAR(600),
        @ObjectID INT,
        @Sql NVARCHAR(MAX),
        @JsonSelectList NVARCHAR(MAX),
        @RowsUpdated BIGINT,
        @TotalRows BIGINT,
        @RowsWithHash BIGINT,
        @DistinctHashKeys BIGINT,
        @DuplicateHashKeys BIGINT,
        @DataTopic NVARCHAR(100),
        @Remarks NVARCHAR(4000),
        @ErrorMessage NVARCHAR(4000),
        @TableID INT,
        @MaxTableID INT,
        @TablesFound INT = 0,
        @TablesSucceeded INT = 0,
        @TablesFailed INT = 0,
        @TotalRowsAcrossTables BIGINT = 0,
        @TotalRowsWithHashAcrossTables BIGINT = 0;

    IF @BatchSize IS NULL OR @BatchSize <= 0
        SET @BatchSize = 50000;

    BEGIN TRY

        ---------------------------------------------------------------------
        -- Ensure log table exists
        ---------------------------------------------------------------------
        IF OBJECT_ID('dbo.FCAP1A_Cohort_Log', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.FCAP1A_Cohort_Log (
                LogID           INT IDENTITY(1,1) PRIMARY KEY,
                RunStart        DATETIME NOT NULL,
                RunEnd          DATETIME NULL,
                DurationSeconds INT NULL,
                RunStatus       VARCHAR(20) NOT NULL,
                DataTopic       NVARCHAR(100) NOT NULL,
                WindowStart     DATE NULL,
                WindowEnd       DATE NULL,
                TotalEligible   INT NULL,
                RecordCount     INT NULL,
                ProcessedBy     NVARCHAR(100) DEFAULT SYSTEM_USER,
                ErrorMessage    NVARCHAR(4000) NULL,
                Remarks         NVARCHAR(4000) NULL
            );
        END;

        ---------------------------------------------------------------------
        -- Discover FCAP 1A output tables
        ---------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#HashTables') IS NOT NULL
            DROP TABLE #HashTables;

        CREATE TABLE #HashTables (
            TableID INT IDENTITY(1,1) PRIMARY KEY,
            SchemaName SYSNAME NOT NULL,
            TableName SYSNAME NOT NULL,
            ObjectID INT NOT NULL,
            FullTableName NVARCHAR(600) NOT NULL
        );

        INSERT INTO #HashTables (
            SchemaName,
            TableName,
            ObjectID,
            FullTableName
        )
        SELECT
            s.name AS SchemaName,
            t.name AS TableName,
            t.object_id AS ObjectID,
            QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) AS FullTableName
        FROM sys.tables t
        INNER JOIN sys.schemas s
            ON s.schema_id = t.schema_id
        WHERE s.name = N'dbo'
          AND t.is_ms_shipped = 0
          AND t.name LIKE N'tbl_FCAP1A%[_]Extended'
          AND (
                @IncludeClinicalNotes = 1
                OR t.name NOT LIKE N'tbl_FCAP1A_ClinicalNotes%'
              )
        ORDER BY
            CASE
                WHEN t.name = N'tbl_FCAP1A_Cohort10_Extended' THEN 1
                ELSE 2
            END,
            t.name;

        SELECT
            @TablesFound = COUNT(*),
            @MaxTableID = MAX(TableID)
        FROM #HashTables;

        IF @TablesFound = 0
        BEGIN
            THROW 51000, 'No dbo.tbl_FCAP1A_%_Extended tables were found for SHA256 hashkey processing.', 1;
        END;

        ---------------------------------------------------------------------
        -- Process each table
        ---------------------------------------------------------------------
        SET @TableID = 1;

        WHILE @TableID <= @MaxTableID
        BEGIN
            SELECT
                @SchemaName = SchemaName,
                @TableName = TableName,
                @ObjectID = ObjectID,
                @FullTableName = FullTableName
            FROM #HashTables
            WHERE TableID = @TableID;

            IF @ObjectID IS NOT NULL
            BEGIN
                SET @CurrentRunStart = SYSDATETIME();
                SET @DataTopic = LEFT(N'HashKey_' + @TableName, 100);
                SET @HashPrefix = N'FCAP1A|' + @SchemaName + N'.' + @TableName + N'|';

                BEGIN TRY

                    -----------------------------------------------------------------
                    -- If recomputing, drop and recreate hashkey so it becomes last
                    -----------------------------------------------------------------
                    IF @RecomputeExisting = 1
                       AND EXISTS (
                            SELECT 1
                            FROM sys.columns
                            WHERE object_id = @ObjectID
                              AND name = N'hashkey'
                       )
                    BEGIN
                        -- Drop any default constraints on hashkey, if present
                        SELECT @Sql = STUFF((
                            SELECT
                                N'; ALTER TABLE ' + @FullTableName +
                                N' DROP CONSTRAINT ' + QUOTENAME(dc.name)
                            FROM sys.default_constraints dc
                            INNER JOIN sys.columns c
                                ON c.object_id = dc.parent_object_id
                               AND c.column_id = dc.parent_column_id
                            WHERE dc.parent_object_id = @ObjectID
                              AND c.name = N'hashkey'
                            FOR XML PATH(''), TYPE
                        ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

                        IF @Sql IS NOT NULL AND LEN(@Sql) > 0
                            EXEC sys.sp_executesql @Sql;

                        SET @Sql = N'ALTER TABLE ' + @FullTableName + N' DROP COLUMN [hashkey];';
                        EXEC sys.sp_executesql @Sql;
                    END;

                    IF NOT EXISTS (
                        SELECT 1
                        FROM sys.columns
                        WHERE object_id = @ObjectID
                          AND name = N'hashkey'
                    )
                    BEGIN
                        SET @Sql = N'ALTER TABLE ' + @FullTableName + N' ADD [hashkey] NVARCHAR(64) NULL;';
                        EXEC sys.sp_executesql @Sql;
                    END;

                    -----------------------------------------------------------------
                    -- Build deterministic JSON column list excluding hashkey
                    -----------------------------------------------------------------
                    SELECT @JsonSelectList = STUFF((
                        SELECT
                            N', ' +
                            CASE
                                WHEN ty.name IN (N'date', N'datetime', N'datetime2', N'smalldatetime', N'datetimeoffset', N'time')
                                    THEN N'CONVERT(NVARCHAR(50), t.' + QUOTENAME(c.name) + N', 126)'

                                WHEN ty.name IN (N'binary', N'varbinary', N'image')
                                    THEN N'CONVERT(NVARCHAR(MAX), CONVERT(VARCHAR(MAX), t.' + QUOTENAME(c.name) + N', 2))'

                                WHEN ty.name IN (N'text', N'ntext', N'xml')
                                    THEN N'CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(c.name) + N')'

                                WHEN ty.name IN (N'float', N'real')
                                    THEN N'CONVERT(NVARCHAR(100), t.' + QUOTENAME(c.name) + N', 3)'

                                ELSE
                                    N'CONVERT(NVARCHAR(MAX), t.' + QUOTENAME(c.name) + N')'
                            END
                            + N' AS ' + QUOTENAME(c.name)
                        FROM sys.columns c
                        INNER JOIN sys.types ty
                            ON ty.user_type_id = c.user_type_id
                        WHERE c.object_id = @ObjectID
                          AND c.name <> N'hashkey'
                          AND c.is_computed = 0
                          AND ty.name NOT IN (N'timestamp', N'rowversion')
                        ORDER BY c.column_id
                        FOR XML PATH(''), TYPE
                    ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

                    IF @JsonSelectList IS NULL OR LEN(@JsonSelectList) = 0
                    BEGIN
                        THROW 51001, 'No eligible source columns found for hashkey generation.', 1;
                    END;

                    -----------------------------------------------------------------
                    -- Update hashkey in batches
                    -----------------------------------------------------------------
                    SET @RowsUpdated = 0;

                    SET @Sql = N'
DECLARE @RowsThisBatch INT = 1;

WHILE @RowsThisBatch > 0
BEGIN
    UPDATE TOP (@BatchSize) t
        SET hashkey =
            CONVERT(
                NVARCHAR(64),
                CONVERT(
                    VARCHAR(64),
                    HASHBYTES(
                        ''SHA2_256'',
                        CONVERT(
                            NVARCHAR(MAX),
                            CONCAT(
                                @HashPrefix,
                                (
                                    SELECT ' + @JsonSelectList + N'
                                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
                                )
                            )
                        )
                    ),
                    2
                )
            )
    FROM ' + @FullTableName + N' AS t
    WHERE t.hashkey IS NULL
       OR LTRIM(RTRIM(t.hashkey)) = N'''';

    SET @RowsThisBatch = @@ROWCOUNT;
    SET @RowsUpdated = @RowsUpdated + @RowsThisBatch;
END;
';

                    EXEC sys.sp_executesql
                        @Sql,
                        N'@BatchSize INT, @HashPrefix NVARCHAR(600), @RowsUpdated BIGINT OUTPUT',
                        @BatchSize = @BatchSize,
                        @HashPrefix = @HashPrefix,
                        @RowsUpdated = @RowsUpdated OUTPUT;

                    -----------------------------------------------------------------
                    -- Validation stats
                    -----------------------------------------------------------------
                    SET @Sql = N'
SELECT
    @TotalRows = COUNT_BIG(1),
    @RowsWithHash = COUNT_BIG(NULLIF(hashkey, N'''')),
    @DistinctHashKeys = COUNT_BIG(DISTINCT NULLIF(hashkey, N''''))
FROM ' + @FullTableName + N';
';

                    EXEC sys.sp_executesql
                        @Sql,
                        N'@TotalRows BIGINT OUTPUT, @RowsWithHash BIGINT OUTPUT, @DistinctHashKeys BIGINT OUTPUT',
                        @TotalRows = @TotalRows OUTPUT,
                        @RowsWithHash = @RowsWithHash OUTPUT,
                        @DistinctHashKeys = @DistinctHashKeys OUTPUT;

                    SET @DuplicateHashKeys = ISNULL(@RowsWithHash, 0) - ISNULL(@DistinctHashKeys, 0);

                    IF @FailOnDuplicateHash = 1 AND @DuplicateHashKeys > 0
                    BEGIN
                        SET @ErrorMessage =
                            CONCAT(
                                'Duplicate hashkeys detected in ',
                                @SchemaName,
                                '.',
                                @TableName,
                                '. DuplicateHashKeys=',
                                @DuplicateHashKeys
                            );

                        THROW 51002, @ErrorMessage, 1;
                    END;

                    SET @CurrentRunEnd = SYSDATETIME();
                    SET @DurationSeconds = DATEDIFF(SECOND, @CurrentRunStart, @CurrentRunEnd);

                    SET @Remarks =
                        CONCAT(
                            'SHA256 hashkey appended successfully. ',
                            'Algorithm=SHA2_256; ',
                            'HashInput=TableName + full source row content excluding hashkey/computed/rowversion columns; ',
                            'RowsUpdated=',
                            @RowsUpdated,
                            '; TotalRows=',
                            @TotalRows,
                            '; RowsWithHash=',
                            @RowsWithHash,
                            '; DistinctHashKeys=',
                            @DistinctHashKeys,
                            '; DuplicateHashKeys=',
                            @DuplicateHashKeys,
                            '; BatchSize=',
                            @BatchSize,
                            '.'
                        );

                    INSERT INTO dbo.FCAP1A_Cohort_Log (
                        RunStart,
                        RunEnd,
                        DurationSeconds,
                        RunStatus,
                        DataTopic,
                        WindowStart,
                        WindowEnd,
                        TotalEligible,
                        RecordCount,
                        ErrorMessage,
                        Remarks
                    )
                    VALUES (
                        @CurrentRunStart,
                        @CurrentRunEnd,
                        @DurationSeconds,
                        'SUCCESS',
                        @DataTopic,
                        NULL,
                        NULL,
                        CASE WHEN @TotalRows > 2147483647 THEN NULL ELSE CONVERT(INT, @TotalRows) END,
                        CASE WHEN @RowsWithHash > 2147483647 THEN NULL ELSE CONVERT(INT, @RowsWithHash) END,
                        NULL,
                        LEFT(@Remarks, 4000)
                    );

                    SET @TablesSucceeded = @TablesSucceeded + 1;
                    SET @TotalRowsAcrossTables = @TotalRowsAcrossTables + ISNULL(@TotalRows, 0);
                    SET @TotalRowsWithHashAcrossTables = @TotalRowsWithHashAcrossTables + ISNULL(@RowsWithHash, 0);

                END TRY
                BEGIN CATCH
                    SET @CurrentRunEnd = SYSDATETIME();
                    SET @DurationSeconds = DATEDIFF(SECOND, @CurrentRunStart, @CurrentRunEnd);
                    SET @ErrorMessage = LEFT(ERROR_MESSAGE(), 4000);

                    INSERT INTO dbo.FCAP1A_Cohort_Log (
                        RunStart,
                        RunEnd,
                        DurationSeconds,
                        RunStatus,
                        DataTopic,
                        WindowStart,
                        WindowEnd,
                        TotalEligible,
                        RecordCount,
                        ErrorMessage,
                        Remarks
                    )
                    VALUES (
                        @CurrentRunStart,
                        @CurrentRunEnd,
                        @DurationSeconds,
                        'FAILED',
                        @DataTopic,
                        NULL,
                        NULL,
                        NULL,
                        NULL,
                        @ErrorMessage,
                        CONCAT(
                            'SHA256 hashkey append failed for ',
                            @SchemaName,
                            '.',
                            @TableName,
                            '.'
                        )
                    );

                    SET @TablesFailed = @TablesFailed + 1;

                    IF @ContinueOnError = 0
                    BEGIN
                        THROW;
                    END;
                END CATCH;
            END;

            SET @TableID = @TableID + 1;
        END;

        ---------------------------------------------------------------------
        -- Final summary log row
        ---------------------------------------------------------------------
        SET @OverallRunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @OverallRunStart, @OverallRunEnd);

        SET @Remarks =
            CONCAT(
                'FCAP 1A SHA256 hashkey post-build process completed. ',
                'TablesFound=',
                @TablesFound,
                '; TablesSucceeded=',
                @TablesSucceeded,
                '; TablesFailed=',
                @TablesFailed,
                '; TotalRowsAcrossTables=',
                @TotalRowsAcrossTables,
                '; TotalRowsWithHashAcrossTables=',
                @TotalRowsWithHashAcrossTables,
                '; Algorithm=SHA2_256; ',
                'RecomputeExisting=',
                @RecomputeExisting,
                '; IncludeClinicalNotes=',
                @IncludeClinicalNotes,
                '; FailOnDuplicateHash=',
                @FailOnDuplicateHash,
                '.'
            );

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @OverallRunStart,
            @OverallRunEnd,
            @DurationSeconds,
            CASE WHEN @TablesFailed = 0 THEN 'SUCCESS' ELSE 'PARTIAL_SUCCESS' END,
            'FCAP1A_SHA256_HashKeys',
            NULL,
            NULL,
            CASE WHEN @TotalRowsAcrossTables > 2147483647 THEN NULL ELSE CONVERT(INT, @TotalRowsAcrossTables) END,
            CASE WHEN @TotalRowsWithHashAcrossTables > 2147483647 THEN NULL ELSE CONVERT(INT, @TotalRowsWithHashAcrossTables) END,
            NULL,
            LEFT(@Remarks, 4000)
        );

    END TRY
    BEGIN CATCH
        SET @OverallRunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @OverallRunStart, @OverallRunEnd);
        SET @ErrorMessage = LEFT(ERROR_MESSAGE(), 4000);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @OverallRunStart,
            @OverallRunEnd,
            @DurationSeconds,
            'FAILED',
            'FCAP1A_SHA256_HashKeys',
            NULL,
            NULL,
            NULL,
            NULL,
            @ErrorMessage,
            CONCAT(
                'FCAP 1A SHA256 hashkey post-build process failed. ',
                'TablesSucceeded=',
                @TablesSucceeded,
                '; TablesFailed=',
                @TablesFailed,
                '; LastTable=',
                ISNULL(@SchemaName + N'.' + @TableName, N'UNKNOWN'),
                '.'
            )
        );

        THROW;
    END CATCH;
END;
GO