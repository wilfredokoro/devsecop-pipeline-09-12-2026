package com.gavok.demo;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
@SpringBootTest
@AutoConfigureMockMvc
class ApplicationTest {
    @Autowired MockMvc mvc;
    @Test void indexIsHealthy() throws Exception {
        mvc.perform(get("/")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("running"));
    }
    @Test void helloIsAvailable() throws Exception {
        mvc.perform(get("/api/hello")).andExpect(status().isOk()).andExpect(jsonPath("$.message").exists());
    }
    @Test void securityHeadersAreApplied() throws Exception {
        mvc.perform(get("/"))
          .andExpect(header().string("X-Frame-Options", "DENY"))
          .andExpect(header().string("X-Content-Type-Options", "nosniff"))
          .andExpect(header().string("Cache-Control", "no-store"))
          .andExpect(header().exists("Content-Security-Policy"));
    }
    @Test void missingPageIsNotExposed() throws Exception {
        mvc.perform(get("/not-a-real-endpoint")).andExpect(status().isNotFound());
    }
}
