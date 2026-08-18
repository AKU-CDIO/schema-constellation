/* Author: test */
USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Flowsheets_Extended]    Script Date: 8/18/2026 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure: usp_Build_FCAP1A_Flowsheets_Extended

    Purpose:
      - Builds the FCAP 1A flowsheets output for the extended 10% cohort.
      - Re-grains the topic to one row per observation instead of one row per visit.
      - Uses the available observation-time proxy:
            PhaPatData     -> COALESCE(LastEventDateTime, RowUpdateDateTime)
            AdmVitalSigns  -> COALESCE(ErTriageDateTime, RowUpdateDateTime)
      - Restricts observations to the fixed cohort window:
            2022-11-05 -> 2026-06-14
      - Leaves growth-chart onboarding as a follow-up source-integration task.
*/

CREATE OR ALTER PROCEDURE [dbo].[usp_Build_FCAP1A_Flowsheets_Extended]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @RunStart DATETIME2(3) = SYSDATETIME(),
        @RunEnd DATETIME2(3),
        @DurationSeconds INT,
        @RecordCount INT = 0,
        @TotalCohort INT = 0,
        @WindowStart DATE = '2022-11-05',
        @WindowEnd DATE = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY, 1, '2026-06-14');

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME2(3) NOT NULL,
            RunEnd          DATETIME2(3) NULL,
            DurationSeconds INT NULL,
            RunStatus       VARCHAR(20) NOT NULL,
            DataTopic       NVARCHAR(100) NOT NULL,
            WindowStart     DATE NULL,
            WindowEnd       DATE NULL,
            TotalEligible   INT NULL,
            RecordCount     INT NULL,
            ProcessedBy     NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000) NULL,
            Remarks         NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_Flowsheets_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Flowsheets_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Flowsheets_Extended (
        PatientID NVARCHAR(50) NOT NULL,
        VisitID NVARCHAR(50) NOT NULL,
        SourceID NVARCHAR(10) NULL,
        ObservationSource NVARCHAR(50) NOT NULL,
        ObservationSourceRowID INT NOT NULL,
        ObservationDateTime DATETIME NULL,
        Sex NVARCHAR(20) NULL,
        Bed NVARCHAR(50) NULL,
        RoomID NVARCHAR(50) NULL,
        LocationID NVARCHAR(50) NULL,
        Status NVARCHAR(50) NULL,
        HeightInCentimeters DECIMAL(18,4) NULL,
        HeightInFeet INT NULL,
        HeightInInches DECIMAL(18,4) NULL,
        WeightInKilograms DECIMAL(18,4) NULL,
        WeightInPounds DECIMAL(18,4) NULL,
        BodySurfaceArea DECIMAL(18,4) NULL,
        DischargeHeightInCentimeters DECIMAL(18,4) NULL,
        DischargeWeightInKg DECIMAL(18,4) NULL,
        BloodPressure NVARCHAR(50) NULL,
        Pulse NVARCHAR(50) NULL,
        Respiration NVARCHAR(50) NULL,
        Temperature NVARCHAR(50) NULL,
        ChiefComplaint NVARCHAR(500) NULL,
        TriageLevelID NVARCHAR(20) NULL,
        TriageLevelName NVARCHAR(100) NULL,
        LastEventDateTime DATETIME NULL,
        DischargeDateTime DATETIME NULL,
        ErTriageDateTime DATETIME NULL,
        RowUpdateDateTime DATETIME NULL,
        ExtractedFrom NVARCHAR(200) NULL,
        ExtractedOn DATETIME2(3) NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT PK_tbl_FCAP1A_Flowsheets_Extended PRIMARY KEY CLUSTERED
        (
            PatientID,
            VisitID,
            ObservationSource,
            ObservationSourceRowID
        )
    );

    CREATE INDEX IX_tbl_FCAP1A_Flowsheets_Extended_ObservationDateTime
        ON dbo.tbl_FCAP1A_Flowsheets_Extended (ObservationDateTime, PatientID, VisitID);

    BEGIN TRY
        SELECT @TotalCohort = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH CohortVisits AS
        (
            SELECT DISTINCT
                c.PatientID,
                v.VisitID
            FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v
                ON c.PatientID COLLATE DATABASE_DEFAULT =
                   v.PatientID COLLATE DATABASE_DEFAULT
            WHERE v.VisitID IS NOT NULL
        ),
        PhaPatDataEvents AS
        (
            SELECT
                cv.PatientID,
                cv.VisitID,
                p.SourceID,
                'PhaPatData' AS ObservationSource,
                ROW_NUMBER() OVER
                (
                    PARTITION BY cv.PatientID, cv.VisitID
                    ORDER BY
                        COALESCE(p.LastEventDateTime, p.RowUpdateDateTime),
                        p.RowUpdateDateTime,
                        p.SourceID
                ) AS ObservationSourceRowID,
                COALESCE(p.LastEventDateTime, p.RowUpdateDateTime) AS ObservationDateTime,
                p.Sex,
                p.Bed,
                p.RoomID,
                p.LocationID,
                p.Status,
                TRY_CAST(p.HeightInCentimeters AS DECIMAL(18,4)) AS HeightInCentimeters,
                p.HeightInFeet,
                TRY_CAST(p.HeightInInches AS DECIMAL(18,4)) AS HeightInInches,
                TRY_CAST(p.WeightInKilograms AS DECIMAL(18,4)) AS WeightInKilograms,
                TRY_CAST(p.WeightInPounds AS DECIMAL(18,4)) AS WeightInPounds,
                TRY_CAST(p.BodySurfaceArea AS DECIMAL(18,4)) AS BodySurfaceArea,
                TRY_CAST(p.DischargeHeightInCentimeters AS DECIMAL(18,4)) AS DischargeHeightInCentimeters,
                TRY_CAST(p.DischargeWeightInKg AS DECIMAL(18,4)) AS DischargeWeightInKg,
                CAST(NULL AS NVARCHAR(50)) AS BloodPressure,
                CAST(NULL AS NVARCHAR(50)) AS Pulse,
                CAST(NULL AS NVARCHAR(50)) AS Respiration,
                CAST(NULL AS NVARCHAR(50)) AS Temperature,
                CAST(NULL AS NVARCHAR(500)) AS ChiefComplaint,
                CAST(NULL AS NVARCHAR(20)) AS TriageLevelID,
                CAST(NULL AS NVARCHAR(100)) AS TriageLevelName,
                p.LastEventDateTime,
                p.DischargeDateTime,
                CAST(NULL AS DATETIME) AS ErTriageDateTime,
                p.RowUpdateDateTime,
                'PhaPatData (observation-time proxy = COALESCE(LastEventDateTime, RowUpdateDateTime))' AS ExtractedFrom
            FROM CohortVisits AS cv
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.PhaPatData AS p
                ON cv.VisitID COLLATE DATABASE_DEFAULT =
                   p.VisitID COLLATE DATABASE_DEFAULT
            WHERE COALESCE(p.LastEventDateTime, p.RowUpdateDateTime) >= @WindowStart
              AND COALESCE(p.LastEventDateTime, p.RowUpdateDateTime) < @WindowEndNextDay
        ),
        AdmVitalSignsEvents AS
        (
            SELECT
                cv.PatientID,
                cv.VisitID,
                vs.SourceID,
                'AdmVitalSigns' AS ObservationSource,
                ROW_NUMBER() OVER
                (
                    PARTITION BY cv.PatientID, cv.VisitID
                    ORDER BY
                        COALESCE(vs.ErTriageDateTime, vs.RowUpdateDateTime),
                        vs.RowUpdateDateTime,
                        vs.SourceID
                ) AS ObservationSourceRowID,
                COALESCE(vs.ErTriageDateTime, vs.RowUpdateDateTime) AS ObservationDateTime,
                CAST(NULL AS NVARCHAR(20)) AS Sex,
                CAST(NULL AS NVARCHAR(50)) AS Bed,
                CAST(NULL AS NVARCHAR(50)) AS RoomID,
                CAST(NULL AS NVARCHAR(50)) AS LocationID,
                CAST(NULL AS NVARCHAR(50)) AS Status,
                CAST(NULL AS DECIMAL(18,4)) AS HeightInCentimeters,
                CAST(NULL AS INT) AS HeightInFeet,
                CAST(NULL AS DECIMAL(18,4)) AS HeightInInches,
                CAST(NULL AS DECIMAL(18,4)) AS WeightInKilograms,
                CAST(NULL AS DECIMAL(18,4)) AS WeightInPounds,
                CAST(NULL AS DECIMAL(18,4)) AS BodySurfaceArea,
                CAST(NULL AS DECIMAL(18,4)) AS DischargeHeightInCentimeters,
                CAST(NULL AS DECIMAL(18,4)) AS DischargeWeightInKg,
                vs.BloodPressure,
                vs.Pulse,
                vs.Respiration,
                vs.Temperature,
                vs.ChiefComplaint,
                vs.TriageLevelID,
                vs.TriageLevelName,
                CAST(NULL AS DATETIME) AS LastEventDateTime,
                CAST(NULL AS DATETIME) AS DischargeDateTime,
                vs.ErTriageDateTime,
                vs.RowUpdateDateTime,
                'AdmVitalSigns (observation-time proxy = COALESCE(ErTriageDateTime, RowUpdateDateTime))' AS ExtractedFrom
            FROM CohortVisits AS cv
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVitalSigns AS vs
                ON cv.VisitID COLLATE DATABASE_DEFAULT =
                   vs.VisitID COLLATE DATABASE_DEFAULT
            WHERE COALESCE(vs.ErTriageDateTime, vs.RowUpdateDateTime) >= @WindowStart
              AND COALESCE(vs.ErTriageDateTime, vs.RowUpdateDateTime) < @WindowEndNextDay
        )
        INSERT INTO dbo.tbl_FCAP1A_Flowsheets_Extended
        (
            PatientID,
            VisitID,
            SourceID,
            ObservationSource,
            ObservationSourceRowID,
            ObservationDateTime,
            Sex,
            Bed,
            RoomID,
            LocationID,
            Status,
            HeightInCentimeters,
            HeightInFeet,
            HeightInInches,
            WeightInKilograms,
            WeightInPounds,
            BodySurfaceArea,
            DischargeHeightInCentimeters,
            DischargeWeightInKg,
            BloodPressure,
            Pulse,
            Respiration,
            Temperature,
            ChiefComplaint,
            TriageLevelID,
            TriageLevelName,
            LastEventDateTime,
            DischargeDateTime,
            ErTriageDateTime,
            RowUpdateDateTime,
            ExtractedFrom
        )
        SELECT
            PatientID,
            VisitID,
            SourceID,
            ObservationSource,
            ObservationSourceRowID,
            ObservationDateTime,
            Sex,
            Bed,
            RoomID,
            LocationID,
            Status,
            HeightInCentimeters,
            HeightInFeet,
            HeightInInches,
            WeightInKilograms,
            WeightInPounds,
            BodySurfaceArea,
            DischargeHeightInCentimeters,
            DischargeWeightInKg,
            BloodPressure,
            Pulse,
            Respiration,
            Temperature,
            ChiefComplaint,
            TriageLevelID,
            TriageLevelName,
            LastEventDateTime,
            DischargeDateTime,
            ErTriageDateTime,
            RowUpdateDateTime,
            ExtractedFrom
        FROM PhaPatDataEvents

        UNION ALL

        SELECT
            PatientID,
            VisitID,
            SourceID,
            ObservationSource,
            ObservationSourceRowID,
            ObservationDateTime,
            Sex,
            Bed,
            RoomID,
            LocationID,
            Status,
            HeightInCentimeters,
            HeightInFeet,
            HeightInInches,
            WeightInKilograms,
            WeightInPounds,
            BodySurfaceArea,
            DischargeHeightInCentimeters,
            DischargeWeightInKg,
            BloodPressure,
            Pulse,
            Respiration,
            Temperature,
            ChiefComplaint,
            TriageLevelID,
            TriageLevelName,
            LastEventDateTime,
            DischargeDateTime,
            ErTriageDateTime,
            RowUpdateDateTime,
            ExtractedFrom
        FROM AdmVitalSignsEvents;

        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_Flowsheets_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'Flowsheets_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalCohort,
            @RecordCount,
            SYSTEM_USER,
            'Flowsheets_Extended rebuilt as one row per observation using documented observation-time proxies for the 2022-11-05 to 2026-06-14 window.'
        );
    END TRY
    BEGIN CATCH
        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            TotalEligible,
            RecordCount,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES
        (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'FAILED',
            'Flowsheets_Extended',
            @WindowStart,
            @WindowEnd,
            @TotalCohort,
            @RecordCount,
            SYSTEM_USER,
            ERROR_MESSAGE(),
            'Flowsheets_Extended observation-grain rebuild failed.'
        );

        THROW;
    END CATCH;
END;
GO
