/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_RadiologyReports_Extended]    Script Date: 7/13/2026 3:34:13 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure  : usp_Build_FCAP1A_RadiologyReports_Extended
    Author            : Allan Z.
    Version           : Extended
    Development Date  : 2026-02-19

    Purpose:
        Builds the FCAP 1A RadiologyReports_Extended dataset
        using PACS imaging metadata from EmrAcctRep_Images.

    Extended Scope Changes:
        - Procedure name appended with _Extended
        - Output table name appended with _Extended
        - Cohort reference switched to tbl_FCAP1A_Cohort10_Extended
        - @WindowEnd set to '2026-01-31' >> later updated to 2026-06-14
        - @WindowEndNextDay derived from @WindowEnd
        - DataTopic label updated
        - ImageDate and ImageTime removed from output
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_RadiologyReports_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart           DATETIME = SYSDATETIME(),
        @RunEnd             DATETIME,
        @DurationSeconds    INT,
        @RecordCount        INT = 0,
        @TotalEligible      INT = 0,
        @WindowStart        DATE = '2022-11-05',
        @WindowEnd          DATE = '2026-06-14',
        @WindowEndNextDay   DATE = DATEADD(DAY, 1, '2026-06-14');

    ----------------------------------------------------------------
    -- Ensure FCAP log table exists
    ----------------------------------------------------------------
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME        NOT NULL,
            RunEnd          DATETIME        NULL,
            DurationSeconds INT             NULL,
            RunStatus       VARCHAR(20)     NOT NULL,
            DataTopic       NVARCHAR(100)   NOT NULL,
            WindowStart     DATE            NULL,
            WindowEnd       DATE            NULL,
            TotalEligible   INT             NULL,
            RecordCount     INT             NULL,
            ProcessedBy     NVARCHAR(100)   NOT NULL DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000)  NULL,
            Remarks         NVARCHAR(4000)  NULL
        );
    END;

    ----------------------------------------------------------------
    -- Drop and recreate Extended target table
    ----------------------------------------------------------------
    IF OBJECT_ID('dbo.tbl_FCAP1A_RadiologyReport_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_RadiologyReport_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_RadiologyReport_Extended
    (
        RadiologyReportRowID      INT IDENTITY(1,1) PRIMARY KEY,

        PatientID                 NVARCHAR(255) NOT NULL,
        VisitID                   NVARCHAR(255) NOT NULL,

        SourceID                  NVARCHAR(50)  NOT NULL,
        DataCategoryID            NVARCHAR(100) NULL,
        DataItemID                NVARCHAR(255) NULL,
        DataUrnID                 NVARCHAR(100) NULL,
        DataKeyID                 NVARCHAR(100) NULL,
        ImageKeyID                INT           NULL,

        Vendor                    NVARCHAR(100) NULL,
        ImageIdentifier           NVARCHAR(255) NULL,
        ImageStatus               NVARCHAR(50)  NULL,
        ImageInterpretationType   NVARCHAR(50)  NULL,
        ImageCount                INT           NULL,
        ImageUrl                  NVARCHAR(2000) NULL,

        ReportDateTime            DATETIME      NULL,
        SourceSystem              NVARCHAR(50)  NOT NULL,
        RowUpdateDateTime         DATETIME      NULL,
        ExtractedOn               DATETIME      NOT NULL DEFAULT (GETDATE())
    );

    BEGIN TRY

        ------------------------------------------------------------
        -- Count eligible Extended cohort patients
        ------------------------------------------------------------
        SELECT @TotalEligible = COUNT(*)
        FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ------------------------------------------------------------
        -- Build cohort visit spine
        ------------------------------------------------------------
        IF OBJECT_ID('tempdb..#CohortVisits') IS NOT NULL
            DROP TABLE #CohortVisits;

        SELECT DISTINCT
            c.PatientID,
            v.VisitID
        INTO #CohortVisits
        FROM dbo.tbl_FCAP1A_Cohort10_Extended AS c
        INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits AS v WITH (NOLOCK)
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
             = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS;

        CREATE CLUSTERED INDEX IX_CohortVisits_VisitID_Extended
            ON #CohortVisits (VisitID);

        ------------------------------------------------------------
        -- Stage PACS imaging metadata within Extended window
        ------------------------------------------------------------
        IF OBJECT_ID('tempdb..#RadiologyImages') IS NOT NULL
            DROP TABLE #RadiologyImages;

        ;WITH Img AS
        (
            SELECT
                e.SourceID,
                e.VisitID,
                e.DataCategoryID,
                e.DataItemID,
                e.DataUrnID,
                e.DataKeyID,
                e.ImageKeyID,
                e.RowUpdateDateTime,
                e.Vendor,
                e.ImageIdentifier,
                TRY_CONVERT(DATETIME, e.ImageDate) AS SafeImageDate,
                e.ImageStatus,
                e.ImageInterpretationType,
                e.ImageCount,
                e.ImageUrl
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.EmrAcctRep_Images AS e WITH (NOLOCK)
        )
        SELECT
            cv.PatientID,
            i.VisitID,
            i.SourceID,
            i.DataCategoryID,
            i.DataItemID,
            i.DataUrnID,
            i.DataKeyID,
            i.ImageKeyID,
            i.Vendor,
            i.ImageIdentifier,
            i.ImageStatus,
            i.ImageInterpretationType,
            i.ImageCount,
            i.ImageUrl,
            i.RowUpdateDateTime,
            i.SafeImageDate AS ReportDateTime
        INTO #RadiologyImages
        FROM Img AS i
        INNER JOIN #CohortVisits AS cv
            ON cv.VisitID COLLATE DATABASE_DEFAULT
             = i.VisitID COLLATE DATABASE_DEFAULT
        WHERE i.SafeImageDate IS NOT NULL
          AND i.SafeImageDate >= @WindowStart
          AND i.SafeImageDate <  @WindowEndNextDay
          AND (i.DataCategoryID = 'DI IMAGING' OR i.DataCategoryID IS NULL);

        CREATE CLUSTERED INDEX IX_RadiologyImages_VisitID_Extended
            ON #RadiologyImages (VisitID);

        ------------------------------------------------------------
        -- Insert into Extended output table
        ------------------------------------------------------------
        INSERT INTO dbo.tbl_FCAP1A_RadiologyReport_Extended
        (
            PatientID, VisitID,
            SourceID, DataCategoryID, DataItemID,
            DataUrnID, DataKeyID, ImageKeyID,
            Vendor, ImageIdentifier,
            ImageStatus, ImageInterpretationType,
            ImageCount, ImageUrl,
            ReportDateTime,
            SourceSystem, RowUpdateDateTime
        )
        SELECT
            ri.PatientID,
            ri.VisitID,
            ri.SourceID,
            ri.DataCategoryID,
            ri.DataItemID,
            ri.DataUrnID,
            ri.DataKeyID,
            ri.ImageKeyID,
            ri.Vendor,
            ri.ImageIdentifier,
            ri.ImageStatus,
            ri.ImageInterpretationType,
            ri.ImageCount,
            ri.ImageUrl,
            ri.ReportDateTime,
            N'Meditech_PACS',
            ri.RowUpdateDateTime
        FROM #RadiologyImages AS ri;

        ------------------------------------------------------------
        -- Logging
        ------------------------------------------------------------
        SELECT @RecordCount = COUNT(*)
        FROM dbo.tbl_FCAP1A_RadiologyReport_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ProcessedBy,
            ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds,
            'SUCCESS', N'RadiologyReports_PACS_Extended',
            @WindowStart, @WindowEnd,
            @TotalEligible, @RecordCount,
            SYSTEM_USER, NULL,
            N'Radiology PACS metadata Extended rebuild: Rows='
                + CAST(@RecordCount AS NVARCHAR(20)) + N'.'
        );

    END TRY
    BEGIN CATCH

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log
        (
            RunStart, RunEnd, DurationSeconds, RunStatus,
            DataTopic, WindowStart, WindowEnd,
            TotalEligible, RecordCount, ProcessedBy,
            ErrorMessage, Remarks
        )
        VALUES
        (
            @RunStart, @RunEnd, @DurationSeconds,
            'FAILED', N'RadiologyReports_PACS_Extended',
            @WindowStart, @WindowEnd,
            @TotalEligible, NULL,
            SYSTEM_USER, @Err,
            N'Error during Radiology PACS metadata Extended rebuild.'
        );

        THROW;

    END CATCH;

END;
