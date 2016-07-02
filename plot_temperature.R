library(data.table)
library(lubridate)
library(ggplot2)
# devtools::install_github('Ather-Energy/ggTimeSeries')
library(ggTimeSeries)
library(RColorBrewer)

clean.file <- function(data){
  # remove empty columns
  data$No. <- NULL
  data$V2 <- NULL
  data$Time <- NULL
  data$"Temperature°C     Humidity%RH" <- NULL
  data$V7 <- NULL
  
  setnames(data,c("time","temperature"))
  
  # convert time to POSIXct
  data$time <- ymd_hms(data$time)
  
  # remove first 15 readings (to remove temperature spike at start)
  data <- data[-c(1:15)]
  return(data)
}

internal.temperature <- data.table()
for (file in list.files(pattern="temperature[0-9]+.tsv")){
  internal.temperature <- rbind(internal.temperature,clean.file(fread(file)))
}

internal.temperature$source <- "Inside Temperature"

# https://datamarket.azure.com/dataset/datagovuk/metofficeweatheropendata
# limit ID > 5300088 & site name == BENSON (3658)
# https://api.datamarket.azure.com/DataGovUK/MetOfficeWeatherOpenData/v1/Observation?$filter=ID%20gt%205300000L%20and%20SiteName%20eq%20%27BENSON%20(3658)%27

# Load primary account key
source("config.R")

external.temperature <- fread(paste0("https://datamarket.azure.com/offer/download?endpoint=https%3A%2F%2Fapi.datamarket.azure.com%2FDataGovUK%2FMetOfficeWeatherOpenData%2Fv1%2F&query=Observation%3F%24filter%3DID%2520gt%25205300000L%2520and%2520SiteName%2520eq%2520%2527BENSON%2520(3658)%2527&accountKey=",api.key,"&title=UK+Met+Office+Weather+Open+Data&name=UK+Met+Office+Weather+Open+Data-Observation"))

external.temperature$ObservationDate <- substr(external.temperature$ObservationDate,0,10)
external.temperature$ObservationTime2 <- ymd_h(paste(external.temperature$ObservationDate,external.temperature$ObservationTime))

# subset
external.temperature <- external.temperature[,.("time"=ObservationTime2,"temperature"=ScreenTemperature,"source"="Outside Temperature (RAF Benson)")]

# 
external.temperature <- external.temperature[time %within% interval(min(internal.temperature$time),max(internal.temperature$time))]

temperature <- rbind(internal.temperature,external.temperature)
temperature$temperature <- as.numeric(temperature$temperature)

# remove outlier data points (-99.00)
temperature <- temperature[temperature>(-30)]

# plot
png("temperature.png",width=900,height=450)
ggplot(temperature, aes(time,temperature,group=source,colour=source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_minor_breaks = "1 day") +  
  scale_y_continuous(breaks =-5:27) +
  theme(legend.position="bottom") +
  labs(x="",y="Temperature (°C)")
dev.off()

png("temperature_calendar.png",width=900,height=450)
ggplot_calendar_heatmap(temperature[source=="Inside Temperature"],'time','temperature') +
  scale_fill_distiller(palette = 'RdBu')
# facet_wrap(~Year, ncol = 1) # for when there's more than one year of data
dev.off()

# set dat month year to the same for all point so can calculate daily fluctuation
temperature$time.only <- as.POSIXct(strftime(temperature$time, format="%H:%M:%S"), format="%H:%M:%S")

# assign each data point to an interval
temperature$interval <- as.POSIXct(cut(temperature$time.only,"5 mins"))

# caclulate mean
daily.temperature <- temperature[,.(mean.temp=mean(temperature)),by=list(source,interval)]

# plot average daily pattern
png("daily_temperature.png",width=900,height=450)
ggplot(daily.temperature, aes(interval,mean.temp,group=source,colour=source)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_labels="%H:%M") +
  theme(legend.position="bottom") +
  labs(x="Time",y="Mean Temperature (°C)")
dev.off()

png("daily_inside_temperature.png",width=900,height=450)
ggplot(daily.temperature[source=="Inside Temperature"], aes(interval,mean.temp)) + 
  geom_line() + 
  theme_minimal() +
  scale_x_datetime(date_labels="%H:%M") +
  labs(x="Time",y="Mean Temperature (°C)")
dev.off()

# plot all temp points over a single day timeframe
ggplot(temperature[source=="Inside Temperature"], aes(time.only,temperature,group=source,colour=source)) + 
  geom_point(alpha = 0.1)
