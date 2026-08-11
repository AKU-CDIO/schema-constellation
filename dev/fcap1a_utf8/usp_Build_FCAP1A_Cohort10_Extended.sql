/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Cohort10_Extended]    Script Date: 7/13/2026 11:44:49 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure: usp_Build_FCAP1A_Cohort10_Extended
    Author   : Allan Zablon
    Summary:
    Builds the FCAP 1A ten percent cohort (extended window) by identifying patients with
    longitudinal activity, defined as four encounters spaced 7 to 98 days
    apart within a fixed window. VIPs are excluded and only patients with
    a valid CountryOfOrigin entry are considered.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Cohort10_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart          DATETIME = SYSDATETIME(),
        @RunEnd            DATETIME,
        @DurationSeconds   INT,
        @TotalEligible     INT,
        @TotalCohort       INT,
        @RecordCount       INT,
        @WindowStart       DATE = '2022-11-05',
        @WindowEnd         DATE = '2026-06-14',
        @WindowEndNextDay  DATE = DATEADD(DAY, 1, '2026-06-14');

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

    BEGIN TRY

        IF OBJECT_ID('tempdb..#Demo') IS NOT NULL DROP TABLE #Demo;

        SELECT DISTINCT 
            CAST(d.PatientID AS NVARCHAR(50)) AS PatientID
        INTO #Demo
        FROM [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Data d WITH (NOLOCK)
        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Main m WITH (NOLOCK)
            ON d.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               m.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE d.CountryOfOrigin_MisCntryID IS NOT NULL
          AND ISNULL(m.Vip, 'N') <> 'Y';

        IF OBJECT_ID('dbo.tbl_FCAP1A_Cohort10_Extended', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_FCAP1A_Cohort10_Extended;

        CREATE TABLE dbo.tbl_FCAP1A_Cohort10_Extended (
            PatientID               NVARCHAR(50) NOT NULL PRIMARY KEY,
            MostRecentEncounterDate DATETIME     NOT NULL,
            EncounterCount          INT          NOT NULL
        );

        CREATE UNIQUE INDEX IX_FCAP1A_Cohort10_Extended_PID
            ON dbo.tbl_FCAP1A_Cohort10_Extended(PatientID);

        ;WITH Enc AS (
            SELECT
                CAST(v.PatientID AS NVARCHAR(50)) AS PatientID,
                CAST(v.RowUpdateDateTime AS DATE) AS EncDate
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v WITH (NOLOCK)
            INNER JOIN #Demo d
                ON d.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.RowUpdateDateTime >= @WindowStart
              AND v.RowUpdateDateTime <  @WindowEndNextDay
              AND v.RowUpdateDateTime IS NOT NULL
        ),
        Seq AS (
            SELECT
                e.PatientID,
                e.EncDate,
                LEAD(e.EncDate,1) OVER (PARTITION BY e.PatientID ORDER BY e.EncDate) AS d1,
                LEAD(e.EncDate,2) OVER (PARTITION BY e.PatientID ORDER BY e.EncDate) AS d2,
                LEAD(e.EncDate,3) OVER (PARTITION BY e.PatientID ORDER BY e.EncDate) AS d3
            FROM Enc e
        ),
        Qual AS (
            SELECT DISTINCT PatientID
            FROM Seq
            WHERE d3 IS NOT NULL
              AND DATEDIFF(DAY, EncDate, d1) BETWEEN 1 AND 98
              AND DATEDIFF(DAY, d1,     d2) BETWEEN 1 AND 98
              AND DATEDIFF(DAY, d2,     d3) BETWEEN 1 AND 98
        ),
        Ranked AS (
            SELECT
                CAST(v.PatientID AS NVARCHAR(50)) AS PatientID,
                COUNT(*) AS EncounterCount,
                MAX(v.RowUpdateDateTime) AS MostRecentEncounterDate,
                ROW_NUMBER() OVER (ORDER BY MAX(v.RowUpdateDateTime) DESC, v.PatientID) AS rnk
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v WITH (NOLOCK)
            INNER JOIN Qual q
                ON q.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.RowUpdateDateTime >= @WindowStart
              AND v.RowUpdateDateTime <  @WindowEndNextDay
              AND v.RowUpdateDateTime IS NOT NULL
            GROUP BY v.PatientID
        ),
        Stats AS (
            SELECT COUNT(DISTINCT v.PatientID) AS total_patients
            FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v WITH (NOLOCK)
            INNER JOIN #Demo d
                ON d.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
                   v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.RowUpdateDateTime >= @WindowStart
              AND v.RowUpdateDateTime <  @WindowEndNextDay
              AND v.RowUpdateDateTime IS NOT NULL
        )
        INSERT INTO dbo.tbl_FCAP1A_Cohort10_Extended
            (PatientID, MostRecentEncounterDate, EncounterCount)
        SELECT
            r.PatientID,
            r.MostRecentEncounterDate,
            r.EncounterCount
        FROM Ranked r
        CROSS JOIN Stats s
        WHERE r.rnk <= CEILING(s.total_patients * 0.10);

        SELECT @TotalEligible = COUNT(DISTINCT v.PatientID)
        FROM [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v WITH (NOLOCK)
        INNER JOIN #Demo d
            ON d.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        WHERE v.RowUpdateDateTime >= @WindowStart
          AND v.RowUpdateDateTime <  @WindowEndNextDay
          AND v.RowUpdateDateTime IS NOT NULL;

        SELECT @TotalCohort = COUNT(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;
        SET @RecordCount = @TotalCohort;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus,
             DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
             'Cohort10_Extended', @WindowStart, @WindowEnd,
             @TotalEligible, @RecordCount, SYSTEM_USER,
             'Extended cohort generated successfully.');

    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();

        INSERT INTO dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, RunStatus, DataTopic,
             WindowStart, WindowEnd, ProcessedBy, ErrorMessage, Remarks)
        VALUES
            (@RunStart, SYSDATETIME(), 'FAILED', 'Cohort10_Extended',
             @WindowStart, @WindowEnd, SYSTEM_USER, @ErrMsg,
             'Error during extended cohort generation.');

        THROW;
    END CATCH;
END;
