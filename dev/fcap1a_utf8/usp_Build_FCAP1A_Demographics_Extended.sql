USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_Demographics_Extended]    Script Date: 7/13/2026 5:17:33 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* 
   Stored Procedure: usp_Build_FCAP1A_Demographics_Extended
   
   Purpose:
     >> Builds FCAP 1A Demographics dataset for the 10 percent cohort
     >> Enriches demographic attributes using NAME-only lookup tables
     >> Deduplicates all lookup tables using ROW_NUMBER
     >> Ensures single-row result per patient
     >> Provides collation-safe joins for linked server access
     >> Logs execution in FCAP1A_Cohort_Log

   Author      : Allan Zablon
   Organization: Aga Khan University – Data Innovation Office
   Date        : 2026-02-18
   Version     : FCAP 1A Phase 1 – Final Demographics Build (Extended)
						 -----
NOTE:

This Sp assumes no multiplicity, experiented it by running >> 
"SELECT PatientID, COUNT(*) AS Cnt
FROM [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Data
GROUP BY PatientID
HAVING COUNT(*) > 1;" 

>> The above returned an empty table, indicating the tables used here are of SCD Type 1.
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_Demographics_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @RunStart DATETIME = SYSDATETIME(),
        @RunEnd DATETIME,
        @DurationSeconds INT,
        @RecordCount INT = 0,
        @WindowStart DATE = '2022-11-05',
        @WindowEnd DATE   = '2026-06-14',
        @WindowEndNextDay DATE = DATEADD(DAY, 1, '2026-06-14');

    
    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID INT IDENTITY(1,1) PRIMARY KEY,
            RunStart DATETIME NOT NULL,
            RunEnd DATETIME NULL,
            DurationSeconds INT NULL,
            RunStatus VARCHAR(20) NOT NULL,
            DataTopic NVARCHAR(100) NOT NULL,
            WindowStart DATE NULL,
            WindowEnd DATE NULL,
            TotalEligible INT NULL,
            RecordCount INT NULL,
            ProcessedBy NVARCHAR(100) DEFAULT SYSTEM_USER,
            ErrorMessage NVARCHAR(4000) NULL,
            Remarks NVARCHAR(4000) NULL
        );
    END;

    
    IF OBJECT_ID('dbo.tbl_FCAP1A_Demographics_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_Demographics_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_Demographics_Extended (
        PatientID NVARCHAR(50) NOT NULL PRIMARY KEY,

        NameLast NVARCHAR(100) NULL,
        NameFirst NVARCHAR(100) NULL,
        NameMiddle NVARCHAR(100) NULL,
        FullName NVARCHAR(200) NULL,
        Sex NVARCHAR(20) NULL,
        LegalSex NVARCHAR(20) NULL,
        Pronouns NVARCHAR(20) NULL,

        Birthdate DATE NULL,
        Age INT NULL,

        Race_Name NVARCHAR(100) NULL,
        Ethnicity_Name NVARCHAR(100) NULL,
        MaritalStatus_Name NVARCHAR(100) NULL,
        Religion_Name NVARCHAR(100) NULL,
        Language_Name NVARCHAR(100) NULL,
        Citizenship_Name NVARCHAR(100) NULL,
        CountryOfOrigin_Name NVARCHAR(100) NULL,
        PlaceOfBirth NVARCHAR(200) NULL,
        EducationLevel NVARCHAR(100) NULL,

        Confidential BIT NULL,
        VipFlag BIT NULL,
        RecordDeleted BIT NULL,
        Expired BIT NULL,
        ExpiredDateTime DATETIME NULL,

        CreatedDateTime DATETIME NULL,
        LastEditDateTime DATETIME NULL,
        RowUpdateDateTime DATETIME NULL,
        ExtractedOn DATETIME NOT NULL DEFAULT SYSDATETIME()
    );

    BEGIN TRY

        ;WITH RaceLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisRaceID ORDER BY MisRaceID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisRace_Main
        ),
        EthnicityLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisEthnicityID ORDER BY MisEthnicityID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisEthnicity_Main
        ),
        MaritalLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisMaritalStatusID ORDER BY MisMaritalStatusID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisMaritalStatus_Main
        ),
        ReligionLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisReligID ORDER BY MisReligID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisRelig_Main
        ),
        LangLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisLangID ORDER BY MisLangID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisLang_Main
        ),
        CountryLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisCntryID ORDER BY MisCntryID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisCntry_Main
        ),
        EduLkp AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY MisEduLvlID ORDER BY MisEduLvlID) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].dbo.MisEduLvl_Main
        )

        INSERT INTO dbo.tbl_FCAP1A_Demographics_Extended (
            PatientID, NameLast, NameFirst, NameMiddle, FullName,
            Sex, LegalSex, Pronouns, Birthdate, Age,
            Race_Name, Ethnicity_Name, MaritalStatus_Name, Religion_Name,
            Language_Name, Citizenship_Name, CountryOfOrigin_Name,
            PlaceOfBirth, EducationLevel,
            Confidential, VipFlag, RecordDeleted,
            Expired, ExpiredDateTime,
            CreatedDateTime, LastEditDateTime, RowUpdateDateTime, ExtractedOn
        )
        SELECT DISTINCT
            c.PatientID,

            m.NameLast,
            m.NameFirst,
            m.NameMiddle,
            RTRIM(LTRIM(CONCAT_WS(' ', m.NameFirst, m.NameMiddle, m.NameLast))),
            m.Sex,
            m.LegalSex_MisSexID,
            m.Pronouns_MisPronounID,

            m.Birthdate,
            CASE 
                WHEN ISNUMERIC(m.Age) = 1 THEN TRY_CONVERT(INT, m.Age)
                WHEN m.Age LIKE '%y%' THEN TRY_CONVERT(INT, LEFT(m.Age, CHARINDEX('y', m.Age + 'y') - 1))
                ELSE NULL
            END,

            race.Name,
            ethn.Name,
            mar.Name,
            rel.Name,
            lang.Name,
            cn1.Name,
            cn2.Name,

            d.PlaceOfBirth,
            edu.Name,

            CASE WHEN m.Confidential = 'Y' THEN 1 ELSE 0 END,
            CASE WHEN m.Vip = 'Y' THEN 1 ELSE 0 END,
            CASE WHEN m.RecordDeleted = 'Y' THEN 1 ELSE 0 END,
            CASE WHEN m.Expired = 'Y' THEN 1 ELSE 0 END,
            m.ExpiredDateTime,

            m.CreatedDateTime,
            m.LastEditDateTime,
            COALESCE(d.RowUpdateDateTime, m.RowUpdateDateTime),
            SYSDATETIME()
        FROM dbo.tbl_FCAP1A_Cohort10_Extended c
        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Main m
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               m.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        LEFT JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Data d
            ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS =
               d.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
        LEFT JOIN RaceLkp race
            ON d.Race_MisRaceID COLLATE SQL_Latin1_General_CP1_CI_AS =
               race.MisRaceID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND race.rn = 1
        LEFT JOIN EthnicityLkp ethn
            ON d.Ethnicity_MisEthnicityID COLLATE SQL_Latin1_General_CP1_CI_AS =
               ethn.MisEthnicityID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND ethn.rn = 1
        LEFT JOIN MaritalLkp mar
            ON d.MaritalStatus_MisMaritalStatusID COLLATE SQL_Latin1_General_CP1_CI_AS =
               mar.MisMaritalStatusID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND mar.rn = 1
        LEFT JOIN ReligionLkp rel
            ON d.Religion_MisReligID COLLATE SQL_Latin1_General_CP1_CI_AS =
               rel.MisReligID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND rel.rn = 1
        LEFT JOIN LangLkp lang
            ON d.Language_MisLangID COLLATE SQL_Latin1_General_CP1_CI_AS =
               lang.MisLangID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND lang.rn = 1
        LEFT JOIN CountryLkp cn1
            ON d.Citizenship_MisCntryID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cn1.MisCntryID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cn1.rn = 1
        LEFT JOIN CountryLkp cn2
            ON d.CountryOfOrigin_MisCntryID COLLATE SQL_Latin1_General_CP1_CI_AS =
               cn2.MisCntryID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND cn2.rn = 1
        LEFT JOIN EduLkp edu
            ON d.EducationLevel_MisEduLvlID COLLATE SQL_Latin1_General_CP1_CI_AS =
               edu.MisEduLvlID COLLATE SQL_Latin1_General_CP1_CI_AS
           AND edu.rn = 1;

    SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_Demographics_Extended;

    SET @RunEnd = SYSDATETIME();
    SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

    INSERT INTO dbo.FCAP1A_Cohort_Log (
        RunStart, RunEnd, DurationSeconds, RunStatus,
        DataTopic, WindowStart, WindowEnd, RecordCount,
        ProcessedBy, Remarks
    ) VALUES (
        @RunStart, @RunEnd, @DurationSeconds, 'SUCCESS',
        'Demographics_Extended', @WindowStart, @WindowEnd, @RecordCount,
        SYSTEM_USER, 'Demographics_Extended rebuild completed successfully.'
    );

    PRINT 'Demographics_Extended complete. Rows: ' + CAST(@RecordCount AS VARCHAR(20));

    END TRY

    BEGIN CATCH
        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart, RunEnd, RunStatus, DataTopic,
            WindowStart, WindowEnd, ProcessedBy, ErrorMessage, Remarks
        )
        VALUES (
           @RunStart, SYSDATETIME(), 'FAILED', 'Demographics_Extended',
           @WindowStart, @WindowEnd, SYSTEM_USER, ERROR_MESSAGE(),
           'Demographics_Extended rebuild failed.'
        );

        THROW;
    END CATCH;
END;
